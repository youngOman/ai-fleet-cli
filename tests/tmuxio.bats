#!/usr/bin/env bats
# lib/tmuxio.sh — 送訊協定的端到端測試,用**真的 tmux**。
#
# 為什麼一定要用真的 tmux:這個檔踩過的坑全部發生在 tmux 與 TUI 的互動邊界上
# (copy-mode 吃掉輸入、composer 收字延遲、長句被折行導致回讀驗證失敗)。
# 把 tmux mock 掉就等於把要測的東西測掉了。
#
# 隔離:一律開在獨立 socket `fleettest`,絕不碰使用者的 session。
# 每個測試自己開 server、teardown 自己收——即使測試中途失敗也會收乾淨。
#
# 假 TUI 用 python3 扮演:這樣 `#{pane_current_command}` 會是 python3 而不是 shell,
# tui_ready 才會回真(它就是靠前景指令名判斷的)。

FT_SOCKET=fleettest

setup() {
  load helpers
  fleet_test_env
  fleet_test_registry
  fleet_test_signals
  fleet_test_tmuxio

  command -v tmux >/dev/null 2>&1 || skip "沒有 tmux"

  # send_verified 內建 sleep,把可調的那段縮短,不然整組測試會跑很久
  export FLEET_SEND_DELAY=0.3

  ft_write_fake_tuis
  ft_start_server || skip "起不了測試用 tmux server"
  SHELL_PANE=$(tmux -L "$FT_SOCKET" list-panes -a -F '#{pane_id}' | head -1)
}

# 上一個測試的 kill-server 與這一個的 new-session 之間有一小段時間,
# tmux 會回報 lost server。重試幾次,不然整組測試會偶發性地全部 skip 掉
# ——而 skip 看起來很像「過了」,這種假綠最危險。
ft_start_server() {
  local i=0
  tmux -L "$FT_SOCKET" kill-server 2>/dev/null || true
  while [ "$i" -lt 10 ]; do
    if tmux -L "$FT_SOCKET" new-session -d -x 120 -y 30 'sh' 2>/dev/null; then
      return 0
    fi
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

teardown() {
  # 失敗時也要收,不然使用者機器上會留一隻孤兒 tmux server
  tmux -L fleettest kill-server 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 假 TUI
# ---------------------------------------------------------------------------

ft_write_fake_tuis() {
  # 會回顯的假 TUI:印一個 composer 提示符,每收到一行就回顯。
  # 終端機的 echo 是開著的,所以送進去的字會即時出現在畫面上——
  # 這正好用來模擬「使用者打到一半」的畫面。
  cat > "$BATS_TEST_TMPDIR/faketui.py" <<'PY'
import sys
PROMPT = "❯ "
sys.stdout.write(PROMPT)
sys.stdout.flush()
for line in sys.stdin:
    sys.stdout.write("GOT " + line.rstrip("\n") + "\n" + PROMPT)
    sys.stdout.flush()
PY

  # 不回顯的假 TUI:關掉終端機 echo 且什麼都不印。
  # 用來模擬「送出去了但畫面上驗不到」——這條路徑會餵給熔斷計數。
  cat > "$BATS_TEST_TMPDIR/faketui_silent.py" <<'PY'
import sys
import termios
fd = sys.stdin.fileno()
attrs = termios.tcgetattr(fd)
attrs[3] = attrs[3] & ~termios.ECHO
termios.tcsetattr(fd, termios.TCSANOW, attrs)
sys.stdout.write("READY\n")
sys.stdout.flush()
for line in sys.stdin:
    pass
PY
}

# ft_new_pane <要跑的命令> — 開一個新 window 並回傳它的 pane id
ft_new_pane() {
  tmux -L "$FT_SOCKET" new-window -P -F '#{pane_id}' -d "$1"
}

ft_tui_pane() {
  local p
  p=$(ft_new_pane "python3 -u '$BATS_TEST_TMPDIR/faketui.py'")
  ft_wait_for "$p" python
  # 一定要等提示符**真的印在畫面上**才回。只等前景指令名的話會有這個競態:
  # python 還沒印提示符,送進去的字先被終端機回顯,提示符才補在後面,
  # 畫面變成「字…提示符」而不是「提示符 字」,composer 判定就會漏。
  ft_wait_prompt "$p"
  printf '%s' "$p"
}

# ft_wait_prompt <pane> — 等假 TUI 的提示符出現在畫面上,最多 5 秒
ft_wait_prompt() {
  local pane=$1 i=0
  while [ "$i" -lt 50 ]; do
    if tmux -L "$FT_SOCKET" capture-pane -p -t "$pane" 2>/dev/null \
        | LC_ALL=C grep -q '❯'; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

ft_silent_pane() {
  local p
  p=$(ft_new_pane "python3 -u '$BATS_TEST_TMPDIR/faketui_silent.py'")
  ft_wait_for "$p" python
  printf '%s' "$p"
}

# ft_wait_for <pane> <前景指令名前綴> — 等 python 真的接手前景,最多 5 秒。
# 不等的話會偶發性地在 python 還沒起來時就判斷 tui_ready,測試變成擲骰子。
ft_wait_for() {
  local pane=$1 want=$2 i=0 cmd
  while [ "$i" -lt 50 ]; do
    cmd=$(tmux -L "$FT_SOCKET" display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null)
    case "$cmd" in "$want"*) return 0 ;; esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# ---------------------------------------------------------------------------
# tui_ready
# ---------------------------------------------------------------------------

@test "tui_ready:假 TUI 在前景時回真" {
  local pane
  pane=$(ft_tui_pane)
  run tui_ready "$FT_SOCKET" "$pane"
  assert_rc 0 "$status"
}

@test "tui_ready:pane 停在 shell 時回假" {
  # TUI 沒起來或正在重啟。這時送訊息就是打在 shell 的提示字元上,
  # 不但沒送到,還會在使用者的 shell 裡留下一行奇怪的命令。
  run tui_ready "$FT_SOCKET" "$SHELL_PANE"
  assert_rc 1 "$status"
}

@test "tui_ready:pane 不存在時回假而不是爆掉" {
  run tui_ready "$FT_SOCKET" '%9999'
  assert_rc 1 "$status"
}

# ---------------------------------------------------------------------------
# pane_capture / pane_in_mode
# ---------------------------------------------------------------------------

@test "pane_capture:讀得到畫面內容" {
  local pane out
  pane=$(ft_tui_pane)
  tmux -L "$FT_SOCKET" send-keys -t "$pane" -l -- 'hello'
  tmux -L "$FT_SOCKET" send-keys -t "$pane" Enter
  sleep 0.5
  out=$(pane_capture "$FT_SOCKET" "$pane")
  assert_contains "$out" "GOT hello"
}

@test "pane_capture:pane 不存在時回空字串而不是讓呼叫端掛掉" {
  # watcher 每 3 秒掃一輪,worker 關掉 pane 是常態。
  run pane_capture "$FT_SOCKET" '%9999'
  assert_rc 0 "$status"
  assert_eq "$output" ""
}

@test "pane_in_mode:一般狀態回假、copy-mode 回真" {
  local pane
  pane=$(ft_tui_pane)
  run pane_in_mode "$FT_SOCKET" "$pane"
  assert_rc 1 "$status"

  tmux -L "$FT_SOCKET" copy-mode -t "$pane"
  run pane_in_mode "$FT_SOCKET" "$pane"
  assert_rc 0 "$status"
}

# ---------------------------------------------------------------------------
# composer_busy_content(純函式)
# ---------------------------------------------------------------------------
# **使用者打字時絕對不能注入。** 實案:通知直接插進使用者打到一半的句子,
# 把「共享」洗成「共」+通知+「享」,使用者根本沒辦法跟指揮官講話。

@test "composer_busy_content:提示符後面有字 → 忙" {
  run composer_busy_content "$(printf '\xe2\x9d\xaf 打到一半的句子')" ""
  assert_rc 0 "$status"
}

@test "composer_busy_content:提示符後面是空的 → 不忙" {
  run composer_busy_content "$(printf '\xe2\x9d\xaf ')" ""
  assert_rc 1 "$status"
}

@test "composer_busy_content:完全沒有提示符 → 不忙" {
  run composer_busy_content "隨便一段沒有輸入框的畫面" ""
  assert_rc 1 "$status"
}

@test "composer_busy_content:有排隊訊息也算不能插隊" {
  run composer_busy_content "Press up to edit queued messages" ""
  assert_rc 0 "$status"
}

@test "composer_busy_content:給了 kind 就用該 adapter 的 composer 規則" {
  run composer_busy_content "$(printf '\xe2\x9d\xaf 打到一半')" cc
  assert_rc 0 "$status"
}

@test "composer_busy_content:真實 fixture 畫面判定正確" {
  run composer_busy_content "$(fixture cc-composer-busy.txt)" cc
  assert_rc 0 "$status" "使用者正在打字的畫面沒被擋下來"

  run composer_busy_content "$(fixture cc-idle.txt)" cc
  assert_rc 1 "$status" "空輸入框被誤判成使用者在打字,通知會永遠送不出去"
}

# ---------------------------------------------------------------------------
# send_verified
# ---------------------------------------------------------------------------
# 回傳碼契約:0 送達 / 1 驗不到(記 attempt) / 2 使用者在打字(不記帳) / 3 TUI 沒起來(不記帳)

@test "send_verified:送達時回 0,而且畫面上真的出現短單號" {
  local pane rc screen
  pane=$(ft_tui_pane)
  rc=0
  send_verified "$FT_SOCKET" "$pane" "📥 cc1 已交報告 r1800000000:修好登入 — 請驗收" "r1800000000" "" || rc=$?
  assert_rc 0 "$rc"

  screen=$(pane_capture "$FT_SOCKET" "$pane")
  assert_contains "$screen" "r1800000000" "回傳 0 卻在畫面上找不到單號"
  assert_contains "$screen" "GOT" "假 TUI 沒有收到整行(Enter 沒送到?)"
}

@test "send_verified:pane 停在 shell 時回 3 而且什麼都沒送出去" {
  local before after rc
  before=$(pane_capture "$FT_SOCKET" "$SHELL_PANE")
  rc=0
  send_verified "$FT_SOCKET" "$SHELL_PANE" "不該出現的訊息 r777" "r777" "" || rc=$?
  assert_rc 3 "$rc"

  after=$(pane_capture "$FT_SOCKET" "$SHELL_PANE")
  # 不比對整個畫面是否逐字相同——shell 的提示符可能在這期間才印出來,
  # 那不是「我們送了東西進去」。要驗的是**訊息本身沒有進去**。
  case "$after" in
    *r777*) fail "訊息被打進使用者的 shell 了" ;;
    *"不該出現的訊息"*) fail "訊息被打進使用者的 shell 了" ;;
  esac
}

@test "send_verified:使用者正在打字時回 2 而且不覆蓋他打的字" {
  local pane before after rc
  pane=$(ft_tui_pane)

  # 先在假 TUI 裡打半句話製造 composer 忙碌的畫面(不按 Enter)。
  # **提示符要一起打出來**——composer 判定看的是「提示符後面有沒有非空白字元」。
  # 舊版這裡只打內容沒打提示符,卻仍然通過,是因為當時 pane_capture 會連
  # scrollback 一起抓,命中了 scrollback 裡的 shell 提示符——測試在測一個假象。
  tmux -L "$FT_SOCKET" send-keys -t "$pane" -l -- '❯ draft half sentence'
  sleep 0.5
  before=$(pane_capture "$FT_SOCKET" "$pane")
  assert_contains "$before" "draft half sentence" "沒能造出使用者打到一半的畫面"

  rc=0
  send_verified "$FT_SOCKET" "$pane" "插隊的通知 r888" "r888" "" || rc=$?
  assert_rc 2 "$rc"

  after=$(pane_capture "$FT_SOCKET" "$pane")
  assert_contains "$after" "draft half sentence" "使用者打的字被洗掉了"
  case "$after" in
    *r888*) fail "使用者在打字卻還是插隊注入了" ;;
  esac
}

@test "send_verified:送出去了但畫面驗不到時回 1" {
  # 這是唯一該記 attempt 的失敗。回傳碼弄錯的話,要不是永遠不熔斷
  # (一直對著壞掉的 pane 送),就是熔斷得太早(真的送到了卻被記帳)。
  local pane rc
  pane=$(ft_silent_pane)
  rc=0
  send_verified "$FT_SOCKET" "$pane" "看不見的訊息 r999" "r999" "" || rc=$?
  assert_rc 1 "$rc"
}

@test "send_verified:pane 在 copy-mode 時會先退出來再送" {
  # copy-mode 會把 send-keys 整包當成捲動 / 選字指令吃掉,訊息一個字都不會進輸入框。
  local pane rc
  pane=$(ft_tui_pane)
  tmux -L "$FT_SOCKET" copy-mode -t "$pane"
  run pane_in_mode "$FT_SOCKET" "$pane"
  assert_rc 0 "$status" "沒能造出 copy-mode 狀態"

  rc=0
  send_verified "$FT_SOCKET" "$pane" "捲動中也要送到 r555" "r555" "" || rc=$?
  assert_rc 0 "$rc" "copy-mode 沒被取消,訊息被吃掉了"

  run pane_in_mode "$FT_SOCKET" "$pane"
  assert_rc 1 "$status" "送完之後 pane 還留在 copy-mode"
}

@test "send_verified:回讀只比對短單號,長訊息被折行也驗得到" {
  # 畫面只有 120 欄。整句 grep 的話,TUI 一折行就必定驗不到 → 每則通知都被記 attempt
  # → 三輪後熔斷,指揮官從此收不到那份報告的通知。
  local pane rc long screen
  pane=$(ft_tui_pane)
  long="📥 cc1 已交報告 r1800000001:這是一段刻意寫得很長很長的主題名稱用來把終端機的一行塞滿並且強迫它折行好幾次以確認回讀驗證只比對短單號 — 請驗收"
  rc=0
  send_verified "$FT_SOCKET" "$pane" "$long" "r1800000001" "" || rc=$?
  assert_rc 0 "$rc" "長訊息折行後驗不到單號"

  screen=$(pane_capture "$FT_SOCKET" "$pane")
  assert_contains "$screen" "r1800000001"
}

@test "send_verified:對不存在的 pane 回 3(不記帳)" {
  local rc=0
  send_verified "$FT_SOCKET" '%9999' "訊息" "r000" "" || rc=$?
  assert_rc 3 "$rc"
}

# ---------------------------------------------------------------------------
# 隔離自檢
# ---------------------------------------------------------------------------

@test "測試只碰 fleettest 這個 socket" {
  # 寫錯 socket 名就是對使用者真的在用的 worker pane 亂送按鍵。
  local refs
  refs=$(LC_ALL=C grep -oE '\-L [A-Za-z_]+' "$BATS_TEST_FILENAME" | sort -u)
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    assert_eq "$line" "-L fleettest" "測試檔裡出現了別的 tmux socket"
  done <<EOF
$refs
EOF
}
