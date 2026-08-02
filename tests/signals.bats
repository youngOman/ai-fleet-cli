#!/usr/bin/env bats
# lib/signals.sh 的訊號判定測試。
#
# 全部用 tests/fixtures/*.txt 餵,不用內嵌字串。理由:訊號規則的真值來源是
# 「worker 畫面長什麼樣」,那是外部事實。畫面改版時換 fixture 就好,不用動測試邏輯。
#
# 每個 fixture 除了驗「被判成預期的狀態」,也驗「**沒有**被誤判成其他狀態」。
# 只驗前者的話,一條寫太寬的 regex(例如 busy 收了 spinner 動詞)可以全綠通過。

setup() {
  load helpers
  fleet_test_signals
  fleet_test_tmuxio   # composer_busy_content 住在 tmuxio.sh
}

# ---------------------------------------------------------------------------
# 斷言工具
# ---------------------------------------------------------------------------

# assert_signals <fixture> <busy> <stuck> <asking> <composer>
# 後四個參數用 Y / n。一次把整排狀態釘死,誤判成別的狀態就會紅。
assert_signals() {
  local f=$1 want_busy=$2 want_stuck=$3 want_asking=$4 want_composer=$5
  local kind content got
  kind=$(fixture_kind "$f")
  content=$(fixture "$f")

  got=n; pane_busy "$kind" "$content" && got=Y
  assert_eq "$got" "$want_busy" "$f:busy 判定錯誤"

  got=n; pane_stuck "$kind" "$content" && got=Y
  assert_eq "$got" "$want_stuck" "$f:stuck 訊號判定錯誤"

  got=n; pane_asking "$kind" "$content" && got=Y
  assert_eq "$got" "$want_asking" "$f:asking 判定錯誤"

  got=n; composer_busy_content "$content" "$kind" && got=Y
  assert_eq "$got" "$want_composer" "$f:composer 判定錯誤"
}

# 真卡住 = 有卡住訊號 **且** 不忙。這是 libexec/fleet-state 的規則,
# 這裡照著算一遍,確認 fixture 餵進去會得到預期結論。
really_stuck() {
  local kind=$1 content=$2
  pane_stuck "$kind" "$content" || return 1
  pane_busy "$kind" "$content" && return 1
  return 0
}

# ---------------------------------------------------------------------------
# 逐個 fixture 的狀態矩陣
# ---------------------------------------------------------------------------

@test "cc-busy:忙碌,而且不可同時被判成卡住或在問問題" {
  assert_signals cc-busy.txt Y n n n
}

@test "cc-idle:閒置,四個狀態全不成立" {
  assert_signals cc-idle.txt n n n n
}

@test "cc-composer-busy:使用者正在打字,除了 composer 之外與閒置無異" {
  assert_signals cc-composer-busy.txt n n n Y
}

@test "cc-stuck-queued:排隊訊息 + 同時在忙 → busy 為真、真卡住為假" {
  assert_signals cc-stuck-queued.txt Y Y n Y

  local content
  content=$(fixture cc-stuck-queued.txt)
  run really_stuck cc "$content"
  assert_rc 1 "$status" "忙碌中的排隊訊息不是卡住,判成卡住會狂發假警報"
}

@test "cc-stuck-idle:排隊訊息 + 不忙 → 這才是真卡住" {
  assert_signals cc-stuck-idle.txt n Y n Y

  local content
  content=$(fixture cc-stuck-idle.txt)
  run really_stuck cc "$content"
  assert_rc 0 "$status" "訊息排著沒人跑,這是真卡住"
}

@test "cc-asking:停在互動選單,不忙也不算卡住" {
  assert_signals cc-asking.txt n n Y Y
}

@test "cx-busy:忙碌,不可被判成卡住" {
  assert_signals cx-busy.txt Y n n n
}

@test "cx-idle:閒置,四個狀態全不成立" {
  assert_signals cx-idle.txt n n n n
}

@test "cx-stuck-pasted:長訊息卡在輸入框 → 不忙 + 卡住訊號 = 真卡住" {
  # composer 是 Y:輸入框裡真的有東西(卡住的貼上內容)。
  # 這時注入通知會直接接在那坨內容後面,所以「不可插隊」是對的判斷。
  assert_signals cx-stuck-pasted.txt n Y n Y

  local content
  content=$(fixture cx-stuck-pasted.txt)
  run really_stuck cx "$content"
  assert_rc 0 "$status" "貼上內容停在輸入框不執行,是最典型的假訊號卡住"
}

@test "cx-autoreply-faster-model:攔截框本身不算忙碌也不算卡住" {
  assert_signals cx-autoreply-faster-model.txt n n n n
}

# ---------------------------------------------------------------------------
# 回歸:busy 不可依賴 spinner 動詞
# ---------------------------------------------------------------------------
# Claude Code 的 spinner 動詞是隨機生成的,抓字必漏;漏了就把正在幹活的 worker
# 誤報成閒置 → 狂發假警報。假警報比沒警報更糟。

@test "回歸:只有隨機 spinner 動詞、沒有結構性訊號 → 不可判成 busy" {
  local content
  content=$(fixture cc-verbs-no-structure.txt)
  run pane_busy cc "$content"
  assert_rc 1 "$status" "busy 抓到了 spinner 動詞。動詞是隨機的,抓字必漏"
}

@test "回歸:只有結構性訊號、一個動詞都沒有 → 必須判成 busy" {
  local content
  content=$(fixture cc-structure-no-verb.txt)
  run pane_busy cc "$content"
  assert_rc 0 "$status" "結構性訊號在,卻沒判成 busy——忙碌 worker 會被誤報閒置"
}

@test "回歸:adapters/cc.conf 的 busy 規則裡不可出現任何 spinner 動詞" {
  local re
  re=$(signals_get cc busy)
  local verb
  for verb in Metamorphosing Boondoggling Razzmatazzing Levitating \
              Enchanting Germinating Befuddling Crunched Brewed Cooked; do
    case "$re" in
      *"$verb"*) fail "busy 規則含 spinner 動詞「$verb」:$re" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# detect_kind
# ---------------------------------------------------------------------------

@test "detect_kind:每個 cc-*.txt 都回 cc" {
  local f
  for f in "$FIXTURE_DIR"/cc-*.txt; do
    run detect_kind "$(cat "$f")"
    assert_rc 0 "$status" "detect_kind 對 $(basename "$f") 失敗"
    assert_eq "$output" "cc" "$(basename "$f") 應被認成 cc"
  done
}

@test "detect_kind:每個 cx-*.txt 都回 cx" {
  local f
  for f in "$FIXTURE_DIR"/cx-*.txt; do
    run detect_kind "$(cat "$f")"
    assert_rc 0 "$status" "detect_kind 對 $(basename "$f") 失敗"
    assert_eq "$output" "cx" "$(basename "$f") 應被認成 cx"
  done
}

@test "detect_kind:認不出來要 return 1 而不是回一個猜的 kind" {
  run detect_kind "這只是一個普通的 shell 提示字元"
  assert_rc 1 "$status"
  assert_eq "$output" ""
}

@test "detect_kind:大小寫不同的中斷提示不可把 codex 認成 claude" {
  # cx-busy.txt 的中斷提示首字母大寫,cc.conf 的 detect 只收小寫那一種。
  # 一旦放寬成不分大小寫,忙碌中的 codex 會被套上 claude 的整組 regex。
  run detect_kind "$(fixture cx-busy.txt)"
  assert_eq "$output" "cx"
}

# ---------------------------------------------------------------------------
# fixture 自身的健全性
# ---------------------------------------------------------------------------

@test "fixture 的註解區必須是惰性的,不可自己命中任何訊號" {
  # 踩過:註解裡寫了訊號字串原文,fixture 靠自己的註解「自證」成 busy,
  # 於是「沒有結構性訊號就不算 busy」那條回歸測試假綠。
  local f b kind comment
  for f in "$FIXTURE_DIR"/*.txt; do
    b=$(basename "$f")
    kind=$(fixture_kind "$b")
    comment=$(fixture_comment "$b")
    [ -n "$comment" ] || fail "$b 沒有來源註解"
    local key
    for key in busy stuck asking detect composer; do
      if signals_match "$kind" "$key" "$comment"; then
        fail "$b 的註解區命中了 $key 規則,註解必須改寫成不含訊號字串原文"
      fi
    done
  done
}

@test "每個 fixture 開頭都標明了來源(真實錄製 / 手工構造)" {
  local f b comment
  for f in "$FIXTURE_DIR"/*.txt; do
    b=$(basename "$f")
    comment=$(fixture_comment "$b")
    case "$comment" in
      *"來源:真實錄製"* | *"來源:手工構造"*) ;;
      *) fail "$b 第一行沒有標明來源" ;;
    esac
  done
}

@test "fixture 檔名前綴都對得上一個真的 adapter" {
  local kinds f b kind hit
  kinds=$(signals_kinds)
  for f in "$FIXTURE_DIR"/*.txt; do
    b=$(basename "$f")
    kind=$(fixture_kind "$b")
    hit=0
    local k
    for k in $kinds; do
      [ "$k" = "$kind" ] && hit=1
    done
    [ "$hit" = 1 ] || fail "$b 的前綴「$kind」沒有對應的 adapters/$kind.conf"
  done
}

# ---------------------------------------------------------------------------
# adapter 檔本身
# ---------------------------------------------------------------------------

@test "adapter 的每一條 regex 餵給 grep -E 都不報語法錯" {
  # adapters/*.conf 是資料檔,寫壞了不會有人發現——直到某天 worker
  # 全部被判成閒置。這條把語法錯誤擋在 CI。
  local conf line key val rc
  for conf in "$REPO_ROOT"/adapters/*.conf; do
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in '' | '#'*) continue ;; esac
      key=${line%%=*}
      val=${line#*=}
      [ "$key" = "$line" ] && continue
      case "$key" in name | command | *_keys) continue ;; esac
      [ -n "$val" ] || continue
      rc=0
      printf 'x\n' | LC_ALL=C grep -qE "$val" >/dev/null 2>&1 || rc=$?
      # 0 = 有中、1 = 沒中,都算語法正確;2 以上才是 grep 報語法錯
      [ "$rc" -le 1 ] || fail "$(basename "$conf") 的 $key 不是合法 ERE(grep rc=$rc):$val"
    done < "$conf"
  done
}

@test "adapter 的 regex 不可含多位元組字元集" {
  # LC_ALL=C 下 [·•] 會被拆成個別位元組,比對結果是錯的。要多選必須用 alternation。
  local conf line key val
  for conf in "$REPO_ROOT"/adapters/*.conf; do
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in '' | '#'*) continue ;; esac
      key=${line%%=*}
      val=${line#*=}
      [ "$key" = "$line" ] && continue
      case "$key" in name | command | *_keys) continue ;; esac
      # 取出所有 [...] 字元集,檢查裡面有沒有非 ASCII
      local sets
      sets=$(printf '%s' "$val" | grep -oE '\[[^]]*\]' || true)
      if printf '%s' "$sets" | LC_ALL=C grep -qE '\[[^]]*[^ -~][^]]*\]'; then
        fail "$(basename "$conf") 的 $key 有含多位元組字元的字元集:$val"
      fi
    done < "$conf"
  done
}

@test "每個 adapter 都定義了狀態判定必需的欄位" {
  local kind key val
  for kind in $(signals_kinds); do
    for key in name command detect ready busy stuck asking; do
      val=$(signals_get "$kind" "$key")
      [ -n "$val" ] || fail "adapters/$kind.conf 缺少 $key"
    done
  done
}

@test "signals_get 取不存在的 key 回空字串而不是報錯" {
  # 注意 key 必須是合法的變數名字元:signals_get 沒有驗 key,
  # 傳非識別字元進去會讓內部的 eval 直接噴 bash 語法錯。
  # 目前所有呼叫端都是寫死的字面 key,所以只釘住這個正常路徑。
  run signals_get cc nosuchkey
  assert_rc 0 "$status"
  assert_eq "$output" ""
}

@test "signals_load 對不存在的 kind 回 1" {
  run signals_load 沒這種kind
  assert_rc 1 "$status"
}

@test "signals_load 拒絕怪異的 kind 名(不可被拿來做路徑穿越)" {
  # signals_load 會 eval 變數名,kind 沒驗字元集就是任意程式碼執行
  run signals_load '../../etc/passwd'
  assert_rc 1 "$status"
  run signals_load 'a;touch /tmp/pwn'
  assert_rc 1 "$status"
}

@test "signals_autoreplies:cx 有一條降級到快模型的自動應答" {
  run signals_autoreplies cx
  assert_rc 0 "$status"
  assert_contains "$output" "Retry with a faster model"
  # 格式是 match<TAB>keys
  assert_contains "$output" "	2"
}

@test "signals_autoreplies:cc 沒有定義自動應答就回空" {
  run signals_autoreplies cc
  assert_rc 0 "$status"
  assert_eq "$output" ""
}

@test "cx 的自動應答規則抓得到攔截框畫面" {
  local content m k hit=0
  content=$(fixture cx-autoreply-faster-model.txt)
  while IFS="$(printf '\t')" read -r m k; do
    [ -n "$m" ] || continue
    if printf '%s' "$content" | LC_ALL=C grep -qE "$m"; then
      hit=1
      assert_eq "$k" "2" "降級攔截框一律選 2(不降級)"
    fi
  done <<EOF
$(signals_autoreplies cx)
EOF
  [ "$hit" = 1 ] || fail "自動應答規則抓不到攔截框畫面"
}

@test "自動應答規則不可誤觸一般畫面" {
  local f b m k content
  for f in "$FIXTURE_DIR"/cx-*.txt; do
    b=$(basename "$f")
    [ "$b" = "cx-autoreply-faster-model.txt" ] && continue
    content=$(cat "$f")
    while IFS="$(printf '\t')" read -r m k; do
      [ -n "$m" ] || continue
      if printf '%s' "$content" | LC_ALL=C grep -qE "$m"; then
        fail "$b 誤觸了自動應答規則「$m」——會對正常工作中的 worker 亂送按鍵"
      fi
    done <<EOF
$(signals_autoreplies cx)
EOF
  done
}

# ---------------------------------------------------------------------------
# LC_ALL=C 與非法位元組
# ---------------------------------------------------------------------------

@test "畫面含非法 UTF-8 位元組時比對不可整個失敗" {
  # macOS 的 grep 在 UTF-8 locale 下遇到非法位元組序列會噴 illegal byte sequence
  # 並失敗——失敗被當成「不符合」,忙碌中的 worker 就被誤判成閒置。
  local content
  content="$(printf 'esc to interrupt\n\xff\xfe 亂碼\n')"
  run pane_busy cc "$content"
  assert_rc 0 "$status" "遇到非法位元組就判不出 busy 了"
}
