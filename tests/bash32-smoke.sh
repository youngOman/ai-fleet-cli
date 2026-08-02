#!/bin/bash
# tests/bash32-smoke.sh — bash 3.2 相容性關卡。
#
# 為什麼需要這一支:
#   專案的相容目標是 macOS 內建的 bash 3.2,但 **bats 1.x 在 bash 3.2 底下
#   無法處理非 ASCII 的測試名稱**(它把測試名編碼成函式名,多位元組字元會被
#   逐 byte 拆壞,結果一個測試都跑不起來)。而這個 repo 的測試名稱是繁體中文。
#   所以 bats 只能跑在較新的 bash 上,bash 3.2 的相容性改用這支腳本把關。
#
# 它做兩件事:
#   1. 對每個 shell 檔跑 `bash -n` 語法檢查——bash 4 才有的語法在這裡就會炸。
#   2. 實際 source 全部 lib 並呼叫代表性函式,確認執行期真的能動
#      (光看語法過不了關:`declare -A` 之類的問題只有跑起來才看得到)。
#
# 用法:/bin/bash tests/bash32-smoke.sh

set -uo pipefail

REPO_ROOT=$(cd -P "$(dirname "$0")/.." >/dev/null 2>&1 && pwd)
FAILED=0

pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; FAILED=1; }

check() {
  # check <說明> <期望值> <實際值>
  if [ "$2" = "$3" ]; then
    pass "$1"
  else
    fail "$1(期望「$2」,實際「$3」)"
  fi
}

printf 'bash 版本:%s\n' "${BASH_VERSION:-未知}"
case "${BASH_VERSION:-}" in
  3.2*) printf '(正在用 bash 3.2 驗相容性)\n' ;;
  *)    printf '提醒:目前不是 bash 3.2,這一輪驗不到真正的相容性門檻。\n' ;;
esac

# ---------------------------------------------------------------------------
# 1. 語法檢查
# ---------------------------------------------------------------------------

printf '\n[1] bash -n 語法檢查\n'
for f in "$REPO_ROOT"/bin/fleet \
         "$REPO_ROOT"/lib/*.sh \
         "$REPO_ROOT"/libexec/fleet-watcher \
         "$REPO_ROOT"/install.sh \
         "$REPO_ROOT"/scripts/*.sh \
         "$REPO_ROOT"/tests/helpers.bash \
         "$REPO_ROOT"/tests/run.sh; do
  [ -f "$f" ] || continue
  if bash -n "$f" 2>/dev/null; then
    pass "${f#"$REPO_ROOT"/}"
  else
    fail "${f#"$REPO_ROOT"/}"
    bash -n "$f" 2>&1 | sed 's/^/       /' >&2
  fi
done

# ---------------------------------------------------------------------------
# 2. 執行期煙霧測試
# ---------------------------------------------------------------------------

printf '\n[2] 載入 lib 並實際呼叫\n'

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fleet-bash32.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

FLEET_LIBDIR="$REPO_ROOT"
FLEET_ADAPTER_DIR="$REPO_ROOT/adapters"
FLEET_HOME="$TMP/home"
FLEET_CONFIG="$TMP/config.env"
FLEET_PROFILE="smoke"
FLEET_REPORTS="$TMP/reports"
NO_COLOR=1
export FLEET_LIBDIR FLEET_ADAPTER_DIR FLEET_HOME FLEET_CONFIG \
       FLEET_PROFILE FLEET_REPORTS NO_COLOR

# shellcheck source=../lib/core.sh
. "$REPO_ROOT/lib/core.sh"    || { fail 'source lib/core.sh'; exit 1; }
pass 'source lib/core.sh'
# shellcheck source=../lib/registry.sh
. "$REPO_ROOT/lib/registry.sh" || { fail 'source lib/registry.sh'; exit 1; }
pass 'source lib/registry.sh'
# shellcheck source=../lib/signals.sh
. "$REPO_ROOT/lib/signals.sh"  || { fail 'source lib/signals.sh'; exit 1; }
pass 'source lib/signals.sh'
# shellcheck source=../lib/tmuxio.sh
. "$REPO_ROOT/lib/tmuxio.sh"   || { fail 'source lib/tmuxio.sh'; exit 1; }
pass 'source lib/tmuxio.sh'

# --- core -------------------------------------------------------------------
printf 'FLEET_POLL_SECS=42\n' > "$FLEET_CONFIG"
fleet_load_config
check 'fleet_load_config' '42' "${FLEET_POLL_SECS:-}"

fleet_init_paths
check 'fleet_init_paths' "$FLEET_HOME/profiles/smoke/registry" "$FLEET_REG"
fleet_ensure_dirs || fail 'fleet_ensure_dirs'

_p='/tmp/a b/'"'"'c'
_got=''
eval "_got=$(fleet_shq "$_p")"
check 'fleet_shq' "$_p" "$_got"

check 'fleet_json_escape' 'a\"b\nc' "$(fleet_json_escape "$(printf 'a"b\nc')")"

fleet_lock smoke && pass 'fleet_lock' || fail 'fleet_lock'
fleet_lock smoke && fail 'fleet_lock 應該互斥' || pass 'fleet_lock 互斥'
fleet_unlock smoke

case "$(fleet_mtime "$FLEET_CONFIG")" in
  '' | *[!0-9]*) fail 'fleet_mtime' ;;
  *) pass 'fleet_mtime' ;;
esac

[ -n "$(fleet_md5 "$FLEET_CONFIG")" ] && pass 'fleet_md5' || fail 'fleet_md5'

# --- registry ---------------------------------------------------------------
reg_add cc1 - '%12' cc || fail 'reg_add'
check 'reg_get / wpane' '%12' "$(wpane cc1)"
check 'reg_ids' 'cc1' "$(reg_ids)"
valid_pane '%12' && pass 'valid_pane 接受 %NN' || fail 'valid_pane 接受 %NN'
valid_pane '0:1.2' && fail 'valid_pane 應拒絕座標' || pass 'valid_pane 拒絕座標'
reg_del cc1
check 'reg_del' '0' "$(reg_count)"

commander_set '%9' agents || fail 'commander_set'
check 'commander_socket' 'agents' "$(commander_socket)"
check 'commander_pane' '%9' "$(commander_pane)"

# --- signals ----------------------------------------------------------------
_busy=$(cat "$REPO_ROOT/tests/fixtures/cc-busy.txt")
_idle=$(cat "$REPO_ROOT/tests/fixtures/cc-idle.txt")
pane_busy cc "$_busy" && pass 'pane_busy(忙碌畫面)' || fail 'pane_busy(忙碌畫面)'
pane_busy cc "$_idle" && fail 'pane_busy 誤判閒置畫面' || pass 'pane_busy(閒置畫面)'
check 'detect_kind' 'cc' "$(detect_kind "$_busy")"
check 'signals_get' 'claude' "$(signals_get cc name)"
[ -n "$(signals_autoreplies cx)" ] && pass 'signals_autoreplies' || fail 'signals_autoreplies'

# --- tmuxio(只測純函式,不碰 tmux)------------------------------------------
composer_busy_content "$(printf '\xe2\x9d\xaf 打到一半')" '' \
  && pass 'composer_busy_content(有字)' || fail 'composer_busy_content(有字)'
composer_busy_content "$(printf '\xe2\x9d\xaf ')" '' \
  && fail 'composer_busy_content 誤判空輸入框' || pass 'composer_busy_content(空)'

# ---------------------------------------------------------------------------

printf '\n'
if [ "$FAILED" -eq 0 ]; then
  printf 'bash 3.2 相容性檢查通過。\n'
  exit 0
fi
printf 'bash 3.2 相容性檢查失敗。\n' >&2
exit 1
