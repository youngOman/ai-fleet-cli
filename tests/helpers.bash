# shellcheck shell=bash
# tests/helpers.bash — bats 共用工具
#
# 兩條硬規則:
#   1. **任何測試都不可碰使用者真實的 $FLEET_HOME / registry / state.json。**
#      所有寫入一律落在 $BATS_TEST_TMPDIR 底下,並且在 fleet_test_env 裡實際
#      驗證過路徑確實在 tmpdir 內才繼續——寫錯一次就是把人家的艦隊登記表洗掉。
#   2. 測試只 source lib/*.sh,不執行 bin/fleet。要測的是函式行為,
#      不是 CLI 的參數剖析(那是另一層)。

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
FIXTURE_DIR="$REPO_ROOT/tests/fixtures"

# fail <訊息...> — bats 沒有內建 assert,自己來
fail() {
  printf '%s\n' "$@" >&2
  return 1
}

assert_ok() {
  local rc=$?
  [ "$rc" -eq 0 ] || fail "期望成功(0),實際 rc=$rc"
}

# assert_eq <實際> <期望> [說明]
assert_eq() {
  if [ "$1" != "$2" ]; then
    fail "${3:-值不符}" "  實際:「$1」" "  期望:「$2」"
  fi
}

# assert_rc <期望碼> <實際碼> [說明]
assert_rc() {
  if [ "$1" != "$2" ]; then
    fail "${3:-回傳碼不符}" "  實際:$2" "  期望:$1"
  fi
}

# assert_contains <內容> <子字串> [說明]
assert_contains() {
  case "$1" in
    *"$2"*) return 0 ;;
  esac
  fail "${3:-找不到預期的子字串}" "  要找:「$2」" "  內容:「$1」"
}

# ---------------------------------------------------------------------------
# 測試環境
# ---------------------------------------------------------------------------

# fleet_test_env — 把所有 fleet 路徑改指到本測試專屬的 tmpdir 並載入 lib。
# 呼叫之後 $FLEET_HOME 一定在 $BATS_TEST_TMPDIR 底下。
fleet_test_env() {
  [ -n "${BATS_TEST_TMPDIR:-}" ] || fail "沒有 BATS_TEST_TMPDIR,拒絕繼續" || return 1

  # 清掉可能從外面帶進來的真實設定,避免測試讀到使用者的 config.env
  unset FLEET_PROFILE_DIR FLEET_REG FLEET_COMMANDER_FILE FLEET_STATE_FILE
  unset FLEET_LOG FLEET_PIDFILE FLEET_LOCKDIR

  export FLEET_LIBDIR="$REPO_ROOT"
  export FLEET_ADAPTER_DIR="$REPO_ROOT/adapters"
  export FLEET_HOME="$BATS_TEST_TMPDIR/fleet-home"
  export FLEET_CONFIG="$BATS_TEST_TMPDIR/config.env"
  export FLEET_PROFILE="testprofile"
  export FLEET_REPORTS="$BATS_TEST_TMPDIR/reports"
  export FLEET_TASKS="$BATS_TEST_TMPDIR/tasks"
  export NO_COLOR=1

  # shellcheck source=../lib/core.sh
  . "$REPO_ROOT/lib/core.sh"
  fleet_init_paths

  # 安全閘:確認真的落在 tmpdir 裡才建目錄
  case "$FLEET_PROFILE_DIR" in
    "$BATS_TEST_TMPDIR"/*) ;;
    *) fail "FLEET_PROFILE_DIR 不在 BATS_TEST_TMPDIR 底下:$FLEET_PROFILE_DIR" || return 1 ;;
  esac

  fleet_ensure_dirs
  mkdir -p "$FLEET_REPORTS" "$FLEET_TASKS"
}

# 額外載入 registry.sh(需要 core.sh 的鎖)
fleet_test_registry() {
  # shellcheck source=../lib/registry.sh
  . "$REPO_ROOT/lib/registry.sh"
}

# 只載入 signals.sh(不需要 core.sh,刻意保持這個獨立性:
# fleet-mon 也是只吃 signals.sh)
fleet_test_signals() {
  export FLEET_LIBDIR="$REPO_ROOT"
  export FLEET_ADAPTER_DIR="$REPO_ROOT/adapters"
  # shellcheck source=../lib/signals.sh
  . "$REPO_ROOT/lib/signals.sh"
}

fleet_test_tmuxio() {
  # shellcheck source=../lib/tmuxio.sh
  . "$REPO_ROOT/lib/tmuxio.sh"
}

# ---------------------------------------------------------------------------
# fixture
# ---------------------------------------------------------------------------

# fixture <檔名> — 印出 fixture 全文
fixture() {
  cat "$FIXTURE_DIR/$1"
}

# fixture_comment <檔名> — 只印出開頭的 # 註解區
fixture_comment() {
  awk '/^#/{print; next} {exit}' "$FIXTURE_DIR/$1"
}

# fixture_kind <檔名> — 從檔名前綴取 kind(cc-busy.txt → cc)
fixture_kind() {
  printf '%s' "${1%%-*}"
}
