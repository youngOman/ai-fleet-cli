#!/usr/bin/env bash
# tests/run.sh — 一鍵跑完整組測試:python unittest + bats + shellcheck。
#
# 設計原則:
#   * 缺工具就**明講並失敗**,不靜默跳過。一個會自己跳過的測試套件等於沒有測試
#     ——CI 全綠但什麼都沒跑,比沒有 CI 更危險。
#   * 任何一項失敗就 exit 1,而且最後印出整體摘要,不用去翻上面幾百行輸出。
#   * bash 3.2 的相容性由 tests/bash32-smoke.sh 單獨把關,不是靠 bats。
#     原因:**bats 1.x 在 bash 3.2 底下無法處理非 ASCII 的測試名稱**
#     (它把測試名編碼成函式名,多位元組字元被逐 byte 拆壞,一個測試都跑不起來),
#     而這個 repo 的測試名稱是繁體中文。詳見那支腳本的檔頭。
#     要指定用哪個 bash 驗相容性:FLEET_TEST_BASH=/path/to/bash bash tests/run.sh

set -uo pipefail

REPO_ROOT=$(cd -P "$(dirname "$0")/.." >/dev/null 2>&1 && pwd)
cd "$REPO_ROOT" || exit 1

# ---------------------------------------------------------------------------
# 輸出
# ---------------------------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'
  C_CYN=$'\033[36m'; C_RST=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YLW=''; C_CYN=''; C_RST=''
fi

FAILED=""
RESULTS=""

section() { printf '\n%s━━━ %s ━━━%s\n' "$C_CYN" "$1" "$C_RST"; }
note()    { printf '%s%s%s\n' "$C_YLW" "$1" "$C_RST"; }
die()     { printf '%s%s%s\n' "$C_RED" "$1" "$C_RST" >&2; exit 1; }

record() {
  local name=$1 rc=$2
  if [ "$rc" -eq 0 ]; then
    RESULTS="${RESULTS}${C_GRN}  ✓ ${name}${C_RST}
"
  else
    RESULTS="${RESULTS}${C_RED}  ✗ ${name}(exit ${rc})${C_RST}
"
    FAILED="${FAILED}${name} "
  fi
}

# ---------------------------------------------------------------------------
# 工具檢查:缺什麼就直接講該裝什麼,不跳過
# ---------------------------------------------------------------------------

MISSING=""
for tool in python3 bats shellcheck; do
  command -v "$tool" >/dev/null 2>&1 || MISSING="$MISSING $tool"
done

if [ -n "$MISSING" ]; then
  printf '%s缺少工具:%s%s\n\n' "$C_RED" "$MISSING" "$C_RST" >&2
  case "$MISSING" in
    *bats* | *shellcheck*)
      printf '  macOS:  brew install bats-core shellcheck\n' >&2
      printf '  Debian: sudo apt-get install -y bats shellcheck\n' >&2
      ;;
  esac
  case "$MISSING" in
    *python3*)
      printf '  python3 是必需的(libexec/fleet-state 與 fleet-mon 都用它)\n' >&2
      ;;
  esac
  printf '\n裝完再跑一次。刻意不自動跳過——跳過的測試套件會給人「全綠」的假象。\n' >&2
  exit 1
fi

command -v tmux >/dev/null 2>&1 \
  || note '提醒:找不到 tmux,tests/tmuxio.bats 會整組 skip(送訊協定不會被驗到)。'

# ---------------------------------------------------------------------------
# 相容性關卡用哪個 bash
# ---------------------------------------------------------------------------

COMPAT_BASH=${FLEET_TEST_BASH:-/bin/bash}
[ -x "$COMPAT_BASH" ] || {
  note "找不到 $COMPAT_BASH,改用 PATH 上的 bash 跑相容性檢查(門檻會比較鬆)"
  COMPAT_BASH=bash
}

printf '%s工具版本%s\n' "$C_CYN" "$C_RST"
printf '  python3    %s\n' "$(python3 -V 2>&1)"
printf '  bats       %s\n' "$(bats --version 2>&1)"
printf '  shellcheck %s\n' "$(shellcheck --version 2>/dev/null | awk '/^version:/{print $2}')"
printf '  bash(跑 bats)      %s\n' \
  "$(bash -c 'printf %s "$BASH_VERSION"' 2>/dev/null)"
printf '  bash(驗 3.2 相容)  %s\n' \
  "$("$COMPAT_BASH" -c 'printf %s "$BASH_VERSION"' 2>/dev/null)"
command -v tmux >/dev/null 2>&1 && printf '  tmux       %s\n' "$(tmux -V)"

# ---------------------------------------------------------------------------
# 1. python unittest
# ---------------------------------------------------------------------------

section 'python unittest'
if ls tests/test_*.py >/dev/null 2>&1; then
  python3 -m unittest discover -s tests -p 'test_*.py' -v
  record 'python unittest' $?
else
  die 'tests/ 下找不到任何 test_*.py'
fi

# ---------------------------------------------------------------------------
# 2. bats
# ---------------------------------------------------------------------------

section 'bats'
if ls tests/*.bats >/dev/null 2>&1; then
  bats tests/*.bats
  record 'bats' $?
else
  die 'tests/ 下找不到任何 .bats'
fi

# ---------------------------------------------------------------------------
# 3. bash 3.2 相容性
# ---------------------------------------------------------------------------

section 'bash 3.2 相容性'
if [ -f tests/bash32-smoke.sh ]; then
  "$COMPAT_BASH" tests/bash32-smoke.sh
  record 'bash 3.2 相容性' $?
else
  die '找不到 tests/bash32-smoke.sh'
fi

# ---------------------------------------------------------------------------
# 4. shellcheck
# ---------------------------------------------------------------------------

section 'shellcheck'
SC_TARGETS=""
for f in bin/fleet lib/*.sh libexec/fleet-watcher install.sh \
         scripts/*.sh tests/helpers.bash tests/run.sh tests/bash32-smoke.sh; do
  [ -f "$f" ] && SC_TARGETS="$SC_TARGETS $f"
done
if [ -n "$SC_TARGETS" ]; then
  printf '檢查:%s\n' "$SC_TARGETS"
  # shellcheck disable=SC2086  # SC_TARGETS 刻意要做欄位切割(bash 3.2 不好用陣列傳)
  # -e SC1091:source 的檔案在別的路徑,不是問題
  shellcheck -S warning -e SC1091 $SC_TARGETS
  record 'shellcheck' $?
else
  die '找不到任何可檢查的 shell 腳本'
fi

# ---------------------------------------------------------------------------
# 摘要
# ---------------------------------------------------------------------------

section '摘要'
printf '%s' "$RESULTS"
if [ -n "$FAILED" ]; then
  printf '\n%s測試失敗:%s%s\n' "$C_RED" "$FAILED" "$C_RST" >&2
  exit 1
fi
printf '\n%s全部通過。%s\n' "$C_GRN" "$C_RST"
exit 0
