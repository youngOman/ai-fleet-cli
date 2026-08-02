#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 版本一致性檢查
#
#   bin/fleet 裡的 FLEET_VERSION="x.y.z"
#   CHANGELOG.md 最上面一筆 ## [x.y.z]
#   → 兩者必須相同
#
# 另外：若這個 repo 有 git remote，會順便檢查 v<version> 這個 tag 是否已存在
# （已存在只警告不 fail —— 重跑 CI 不該因此變紅）。
#
# 相容性：bash 3.2（macOS 內建）。不用關聯陣列、不用 mapfile。
# ---------------------------------------------------------------------------
set -eu

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

FLEET_BIN="$REPO_ROOT/bin/fleet"
CHANGELOG="$REPO_ROOT/CHANGELOG.md"

SEMVER_RE='[0-9]+\.[0-9]+\.[0-9]+'

# 注意：bash 3.2 在展開 "$VAR中文" 時會把 UTF-8 首個 byte 當成變數名的一部分，
# 造成 set -u 誤判 unbound。所以錯誤訊息一律走 printf 的 %s，
# 不在字串裡直接把變數和中文黏在一起。
die() {
    fmt=$1
    shift
    # shellcheck disable=SC2059  # fmt 是本檔自己寫死的格式字串，不是外部輸入
    printf "錯誤：$fmt\n" "$@" >&2
    exit 1
}

# --- 1. bin/fleet 的 FLEET_VERSION ----------------------------------------

if [ ! -f "$FLEET_BIN" ]; then
    die '找不到 %s（CLI 主程式尚未建立，無法檢查版本一致性）' "$FLEET_BIN"
fi

bin_match=$(grep -n -E '^[[:space:]]*(readonly[[:space:]]+|export[[:space:]]+)?FLEET_VERSION=' \
    "$FLEET_BIN" | head -n 1 || true)

if [ -z "$bin_match" ]; then
    die '%s 裡找不到 FLEET_VERSION="x.y.z" 這一行' "$FLEET_BIN"
fi

bin_line=${bin_match%%:*}
bin_version=$(printf '%s\n' "$bin_match" | grep -o -E "$SEMVER_RE" | head -n 1 || true)

if [ -z "$bin_version" ]; then
    die 'bin/fleet:%s 的 FLEET_VERSION 不是合法的 x.y.z：%s' "$bin_line" "$bin_match"
fi

# --- 2. CHANGELOG.md 最上面一筆版本 ----------------------------------------

if [ ! -f "$CHANGELOG" ]; then
    die '找不到 %s' "$CHANGELOG"
fi

log_match=$(grep -n -E "^##[[:space:]]*\\[$SEMVER_RE\\]" "$CHANGELOG" | head -n 1 || true)

if [ -z "$log_match" ]; then
    die '%s 裡找不到任何 "## [x.y.z]" 版本標題' "$CHANGELOG"
fi

log_line=${log_match%%:*}
log_version=$(printf '%s\n' "$log_match" | grep -o -E "$SEMVER_RE" | head -n 1)

# --- 3. 比對 ---------------------------------------------------------------

if [ "$bin_version" != "$log_version" ]; then
    printf '錯誤：版本不一致\n' >&2
    printf '  bin/fleet:%s      FLEET_VERSION = %s\n' "$bin_line" "$bin_version" >&2
    printf '  CHANGELOG.md:%s   ## [%s]\n' "$log_line" "$log_version" >&2
    printf '請讓兩邊一致後再發版。\n' >&2
    exit 1
fi

printf '版本一致：%s\n' "$bin_version"
printf '  bin/fleet:%s\n' "$bin_line"
printf '  CHANGELOG.md:%s\n' "$log_line"

# --- 4. tag 是否已存在（只警告） -------------------------------------------

if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    if [ -n "$(git -C "$REPO_ROOT" remote)" ]; then
        if [ -n "$(git -C "$REPO_ROOT" tag -l "v$bin_version")" ]; then
            printf '警告：tag v%s 已經存在，發版前請先 bump 版本。\n' "$bin_version" >&2
        else
            printf '  tag v%s 尚未存在，可以發版。\n' "$bin_version"
        fi
    fi
fi

exit 0
