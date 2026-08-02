#!/usr/bin/env bats
# lib/core.sh — 設定載入 / 跳脫 / 鎖。
#
# 這裡最要緊的是 fleet_load_config 的三條安全規則:設定檔是使用者手寫的純文字,
# 載入方式一旦寫鬆,設定檔就等於任意程式碼執行(而且是在 watcher 這個
# 長時間背景行程裡)。

setup() {
  load helpers
  fleet_test_env
  CONF="$FLEET_CONFIG"
}

# write_conf <行...> — 寫測試用的 config.env
write_conf() {
  printf '%s\n' "$@" > "$CONF"
}

# ---------------------------------------------------------------------------
# fleet_load_config
# ---------------------------------------------------------------------------

@test "載入正常的 FLEET_ key" {
  write_conf 'FLEET_IDLE_SECS=45'
  unset FLEET_IDLE_SECS
  fleet_load_config
  assert_eq "$FLEET_IDLE_SECS" "45"
}

@test "設定檔不存在時安靜地什麼都不做" {
  rm -f "$CONF"
  run fleet_load_config
  assert_rc 0 "$status"
}

@test "# 開頭的註解與空行都略過" {
  write_conf '# 這是註解' '' 'FLEET_POLL_SECS=9' '   '
  unset FLEET_POLL_SECS
  fleet_load_config
  assert_eq "$FLEET_POLL_SECS" "9"
}

@test "只吃 FLEET_ 開頭的 key:PATH 不可被設定檔改掉" {
  # 設定檔能改 PATH / LD_PRELOAD 的話,watcher 每 3 秒就幫人執行一次別的東西
  local before="$PATH"
  write_conf 'PATH=/壞路徑' 'FLEET_POLL_SECS=9'
  unset FLEET_POLL_SECS
  fleet_load_config 2>/dev/null
  assert_eq "$PATH" "$before" "PATH 被設定檔改掉了"
  assert_eq "$FLEET_POLL_SECS" "9" "同一個檔裡合法的那行仍要生效"
}

@test "只吃 FLEET_ 開頭的 key:小寫與其他前綴都拒絕" {
  write_conf 'fleet_poll_secs=9' 'OTHER_THING=9' 'FLEETX=9'
  fleet_load_config 2>/dev/null
  [ -z "${fleet_poll_secs:-}" ] || fail "小寫 key 被載入了"
  [ -z "${OTHER_THING:-}" ] || fail "非 FLEET_ 前綴的 key 被載入了"
  [ -z "${FLEETX:-}" ] || fail "FLEETX 不是 FLEET_ 開頭,不該被載入"
}

@test "拒絕含反引號的值" {
  write_conf 'FLEET_REPORTS=`whoami`'
  unset FLEET_REPORTS
  fleet_load_config 2>/dev/null
  [ -z "${FLEET_REPORTS:-}" ] || fail "含反引號的值被載入了:$FLEET_REPORTS"
}

@test "拒絕含 \$( 的值" {
  write_conf 'FLEET_REPORTS=$(whoami)'
  unset FLEET_REPORTS
  fleet_load_config 2>/dev/null
  [ -z "${FLEET_REPORTS:-}" ] || fail "含命令替換的值被載入了:$FLEET_REPORTS"
}

@test "拒絕夾在中間的命令替換" {
  write_conf 'FLEET_REPORTS=/tmp/$(id -u)/reports'
  unset FLEET_REPORTS
  fleet_load_config 2>/dev/null
  [ -z "${FLEET_REPORTS:-}" ] || fail "命令替換不在開頭就漏掉了:$FLEET_REPORTS"
}

@test "被拒絕的那一行不影響同一個檔裡的其他行" {
  write_conf 'FLEET_TASKS=`whoami`' 'FLEET_POLL_SECS=7'
  unset FLEET_TASKS FLEET_POLL_SECS
  fleet_load_config 2>/dev/null
  [ -z "${FLEET_TASKS:-}" ] || fail "危險的值被載入了"
  assert_eq "$FLEET_POLL_SECS" "7"
}

@test "真實環境變數優先於設定檔" {
  write_conf 'FLEET_IDLE_SECS=45'
  export FLEET_IDLE_SECS=999
  fleet_load_config
  assert_eq "$FLEET_IDLE_SECS" "999" "設定檔蓋掉了真實環境變數"
}

@test "環境變數是空字串也算已設定,設定檔不可覆蓋" {
  # 用 FLEET_LINT_REPORTS= 明確關掉某個功能是合法用法
  write_conf 'FLEET_LINT_REPORTS=1'
  export FLEET_LINT_REPORTS=""
  fleet_load_config
  assert_eq "$FLEET_LINT_REPORTS" "" "空字串環境變數被設定檔蓋掉了"
}

@test "去掉包住整個值的雙引號" {
  write_conf 'FLEET_REPORTS="/tmp/我的 報告"'
  unset FLEET_REPORTS
  fleet_load_config
  assert_eq "$FLEET_REPORTS" "/tmp/我的 報告"
}

@test "去掉包住整個值的單引號" {
  write_conf "FLEET_REPORTS='/tmp/我的 報告'"
  unset FLEET_REPORTS
  fleet_load_config
  assert_eq "$FLEET_REPORTS" "/tmp/我的 報告"
}

@test "值中間的引號保留不動" {
  write_conf 'FLEET_SESSION=a"b"c'
  unset FLEET_SESSION
  fleet_load_config
  assert_eq "$FLEET_SESSION" 'a"b"c'
}

@test "key 前後的空白會被去掉" {
  write_conf '  FLEET_POLL_SECS  =11'
  unset FLEET_POLL_SECS
  fleet_load_config
  assert_eq "$FLEET_POLL_SECS" "11"
}

@test "值裡的空白保留(路徑可能刻意有空白)" {
  write_conf 'FLEET_REPORTS=/tmp/a b/c'
  unset FLEET_REPORTS
  fleet_load_config
  assert_eq "$FLEET_REPORTS" "/tmp/a b/c"
}

@test "值可以是空的" {
  write_conf 'FLEET_LINT_REPORTS='
  unset FLEET_LINT_REPORTS
  fleet_load_config
  [ "${FLEET_LINT_REPORTS+x}" = "x" ] || fail "空值的 key 沒有被設定"
  assert_eq "$FLEET_LINT_REPORTS" ""
}

@test "值裡有等號時只切第一個" {
  write_conf 'FLEET_SESSION=a=b=c'
  unset FLEET_SESSION
  fleet_load_config
  assert_eq "$FLEET_SESSION" "a=b=c"
}

@test "沒有等號的行會被略過並警告" {
  write_conf '這一行沒有等號' 'FLEET_POLL_SECS=5'
  unset FLEET_POLL_SECS
  run fleet_load_config
  assert_contains "$output" "不是 KEY=value"
  fleet_load_config 2>/dev/null
  assert_eq "$FLEET_POLL_SECS" "5"
}

@test "最後一行沒有換行字元也讀得到" {
  printf 'FLEET_POLL_SECS=13' > "$CONF"
  unset FLEET_POLL_SECS
  fleet_load_config
  assert_eq "$FLEET_POLL_SECS" "13"
}

@test "載入的值有被 export(watcher 的啟動器要靠這個傳下去)" {
  write_conf 'FLEET_POLL_SECS=17'
  unset FLEET_POLL_SECS
  fleet_load_config
  assert_eq "$(sh -c 'printf %s "$FLEET_POLL_SECS"')" "17"
}

# ---------------------------------------------------------------------------
# fleet_init_paths
# ---------------------------------------------------------------------------

@test "fleet_init_paths 拒絕怪異的 FLEET_PROFILE" {
  run env FLEET_PROFILE='../../etc' bash -c '
    . "'"$REPO_ROOT"'/lib/core.sh"
    fleet_init_paths
  '
  assert_rc 1 "$status"
  assert_contains "$output" "FLEET_PROFILE"
}

@test "profile 目錄佈局符合契約" {
  assert_eq "$FLEET_PROFILE_DIR" "$FLEET_HOME/profiles/$FLEET_PROFILE"
  assert_eq "$FLEET_REG" "$FLEET_PROFILE_DIR/registry"
  assert_eq "$FLEET_COMMANDER_FILE" "$FLEET_PROFILE_DIR/commander"
  assert_eq "$FLEET_STATE_FILE" "$FLEET_PROFILE_DIR/state.json"
  assert_eq "$FLEET_LOCKDIR" "$FLEET_PROFILE_DIR/locks"
}

# ---------------------------------------------------------------------------
# fleet_shq
# ---------------------------------------------------------------------------
# watcher 會把路徑寫進 watch-launch.sh。沒跳脫的話,含空白或引號的路徑
# 貼進那個檔就是語法錯誤,watcher 起不來而且錯誤訊息完全看不出原因。

@test "fleet_shq:普通路徑" {
  assert_eq "$(fleet_shq /tmp/a)" "'/tmp/a'"
}

@test "fleet_shq:含空白的路徑 eval 回來要一模一樣" {
  local p='/tmp/我的 報告 目錄'
  local got
  eval "got=$(fleet_shq "$p")"
  assert_eq "$got" "$p"
}

@test "fleet_shq:含單引號的路徑 eval 回來要一模一樣" {
  local p="/tmp/it's a dir/x"
  local got
  eval "got=$(fleet_shq "$p")"
  assert_eq "$got" "$p"
}

@test "fleet_shq:含雙引號與錢字號的路徑不會被展開" {
  local p='/tmp/$HOME "quoted"/x'
  local got
  eval "got=$(fleet_shq "$p")"
  assert_eq "$got" "$p"
}

@test "fleet_shq:含分號與反引號的字串不會被執行" {
  local p='a; touch /tmp/絕對不可以出現; echo `id`'
  local got
  eval "got=$(fleet_shq "$p")"
  assert_eq "$got" "$p"
  [ ! -e '/tmp/絕對不可以出現' ] || fail "fleet_shq 讓命令跑掉了"
}

@test "fleet_shq:空字串" {
  local got
  eval "got=$(fleet_shq '')"
  assert_eq "$got" ""
}

# ---------------------------------------------------------------------------
# fleet_json_escape
# ---------------------------------------------------------------------------
# watcher 每 3 秒寫一行 JSON Lines。跳脫寫錯的話日誌會變成不可解析的垃圾,
# 而 `fleet watch log` 正是排查「為什麼沒收到通知」的唯一工具。

# assert_json_ok <原始字串> — 把它包成 JSON 字串後餵給 python json.loads
assert_json_ok() {
  local raw=$1 escaped json got
  escaped=$(fleet_json_escape "$raw")
  json="{\"v\":\"$escaped\"}"
  got=$(printf '%s' "$json" | python3 -c '
import json, sys
print(json.load(sys.stdin)["v"], end="")
') || fail "產出的不是合法 JSON:$json"
  assert_eq "$got" "$raw" "JSON 解回來的值與原始字串不同"
}

@test "fleet_json_escape:純文字" {
  assert_json_ok "一般訊息"
}

@test "fleet_json_escape:含雙引號" {
  assert_json_ok '他說「"這樣"」'
}

@test "fleet_json_escape:含反斜線" {
  assert_json_ok 'C:\path\to\x'
}

@test "fleet_json_escape:反斜線接雙引號(最容易寫反順序的組合)" {
  # 先跳脫引號再跳脫反斜線的話,跳脫用的反斜線會再被跳脫一次 → JSON 壞掉
  assert_json_ok 'a\"b'
}

@test "fleet_json_escape:含換行與 tab" {
  assert_json_ok "$(printf 'a\tb\nc')"
}

@test "fleet_json_escape:含 UTF-8 與 emoji" {
  assert_json_ok '📥 cc1 已交報告:修好登入'
}

@test "fleet_json_escape:空字串" {
  assert_json_ok ''
}

@test "fleet_log 產出可解析的 JSON Lines" {
  FLEET_LOG="$BATS_TEST_TMPDIR/watch.log"
  fleet_log info report-notified 'worker=cc1' 'path=/tmp/我的 "報告".md'
  fleet_log warn 'report-notify-unverified' 'tag=r123'
  run python3 -c '
import json, sys
n = 0
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if line:
        json.loads(line)
        n += 1
print(n)
' "$FLEET_LOG"
  assert_rc 0 "$status"
  assert_eq "$output" "2"
}

@test "fleet_log 丟掉 key 不合法的欄位而不是產出壞 JSON" {
  FLEET_LOG="$BATS_TEST_TMPDIR/watch.log"
  fleet_log info test 'good=1' 'bad key=2' 'x"y=3'
  run python3 -c '
import json, sys
d = json.loads(open(sys.argv[1], encoding="utf-8").readline())
print(",".join(sorted(d.keys())))
' "$FLEET_LOG"
  assert_rc 0 "$status"
  assert_eq "$output" "event,good,level,ts"
}

# ---------------------------------------------------------------------------
# 鎖
# ---------------------------------------------------------------------------

@test "fleet_lock / fleet_unlock 互斥" {
  run fleet_lock 測試鎖
  assert_rc 0 "$status"
  run fleet_lock 測試鎖
  assert_rc 1 "$status"
  fleet_unlock 測試鎖
  run fleet_lock 測試鎖
  assert_rc 0 "$status"
}

@test "fleet_lock 在不同行程之間也互斥" {
  # mkdir 是 bash 唯一可攜的原子 CAS(macOS 沒有 flock)。
  # 只在同一個 shell 裡測的話,測不到跨行程這個真正的使用情境。
  fleet_lock 跨行程
  run env FLEET_LOCKDIR="$FLEET_LOCKDIR" bash -c '
    . "'"$REPO_ROOT"'/lib/core.sh"
    fleet_lock 跨行程
  '
  assert_rc 1 "$status" "另一個行程也拿到了同一把鎖"
  fleet_unlock 跨行程
}

@test "同時搶鎖只有一個成功" {
  local out="$BATS_TEST_TMPDIR/winners"
  : > "$out"
  local i
  for i in $(seq 1 20); do
    ( fleet_lock 搶 && printf 'win\n' >> "$out" ) &
  done
  wait
  assert_eq "$(wc -l < "$out" | tr -d ' ')" "1" "同一把鎖被多個行程同時拿到"
}

# ---------------------------------------------------------------------------
# 跨平台小工具
# ---------------------------------------------------------------------------

@test "fleet_mtime 讀得到 mtime(BSD 與 GNU stat 旗標不同)" {
  local f="$BATS_TEST_TMPDIR/x"
  : > "$f"
  run fleet_mtime "$f"
  assert_rc 0 "$status"
  case "$output" in
    '' | *[!0-9]*) fail "fleet_mtime 沒有回傳純數字:$output" ;;
  esac
}

@test "fleet_md5 對同內容給同雜湊、對不同內容給不同雜湊" {
  local a="$BATS_TEST_TMPDIR/a" b="$BATS_TEST_TMPDIR/b" c="$BATS_TEST_TMPDIR/c"
  printf '同樣的內容' > "$a"
  printf '同樣的內容' > "$b"
  printf '不一樣' > "$c"
  assert_eq "$(fleet_md5 "$a")" "$(fleet_md5 "$b")"
  [ "$(fleet_md5 "$a")" != "$(fleet_md5 "$c")" ] || fail "不同內容給了相同雜湊"
}

@test "fleet_resolve_dir 解得開 symlink 鏈" {
  local real="$BATS_TEST_TMPDIR/real"
  mkdir -p "$real"
  : > "$real/f"
  ln -s "$real/f" "$BATS_TEST_TMPDIR/l1"
  ln -s "$BATS_TEST_TMPDIR/l1" "$BATS_TEST_TMPDIR/l2"
  run fleet_resolve_dir "$BATS_TEST_TMPDIR/l2"
  assert_rc 0 "$status"
  assert_eq "$output" "$(cd -P "$real" && pwd)"
}

@test "fleet_resolve_dir 解得開相對路徑的 symlink" {
  mkdir -p "$BATS_TEST_TMPDIR/d"
  : > "$BATS_TEST_TMPDIR/d/f"
  ln -s "d/f" "$BATS_TEST_TMPDIR/rel"
  run fleet_resolve_dir "$BATS_TEST_TMPDIR/rel"
  assert_rc 0 "$status"
  assert_eq "$output" "$(cd -P "$BATS_TEST_TMPDIR/d" && pwd)"
}

@test "NO_COLOR 時不輸出 ANSI 跳脫序列" {
  run env NO_COLOR=1 bash -c '. "'"$REPO_ROOT"'/lib/core.sh"; fleet_info 訊息'
  assert_eq "$output" "訊息"
}
