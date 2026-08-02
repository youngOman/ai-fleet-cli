# shellcheck shell=bash
# core.sh — 路徑解析 / 設定載入 / 顏色 / 結構化日誌
#
# 由 bin/fleet 與 libexec/fleet-watcher source,不可直接執行。
# 相容目標:bash 3.2(macOS 內建)——不可使用關聯陣列、${var,,}、mapfile。

# 防重複載入
[ -n "${_FLEET_CORE_LOADED:-}" ] && return 0
_FLEET_CORE_LOADED=1

# ---------------------------------------------------------------------------
# 路徑解析
# ---------------------------------------------------------------------------

# 解析 symlink 鏈,回傳最終檔案所在目錄的絕對路徑。
# 不用 `readlink -f`:BSD readlink 在舊 macOS 沒有 -f,行為不可攜。
fleet_resolve_dir() {
  local p="$1" d
  while [ -L "$p" ]; do
    d=$(cd -P "$(dirname "$p")" >/dev/null 2>&1 && pwd) || return 1
    p=$(readlink "$p") || return 1
    case "$p" in
      /*) ;;
      *) p="$d/$p" ;;
    esac
  done
  cd -P "$(dirname "$p")" >/dev/null 2>&1 && pwd
}

# ---------------------------------------------------------------------------
# 設定載入
# ---------------------------------------------------------------------------

fleet_config_path() {
  printf '%s' "${FLEET_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/fleet/config.env}"
}

# 載入 config.env。格式是一行一條 KEY=value,# 開頭是註解。
# 刻意不用 TOML:bash 沒有可靠的 TOML parser,自己寫一個是 bug 工廠。
#
# 三條安全規則:
#   1. 只接受 FLEET_ 開頭的 key(避免設定檔改掉 PATH / LD_PRELOAD)
#   2. 值不得含 ` 或 $( (避免設定檔變成任意程式碼執行)
#   3. 真實環境變數優先——已經在環境裡的 key 一律不覆寫
fleet_load_config() {
  local f n=0 line key val
  f=$(fleet_config_path)
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in '' | '#'*) continue ;; esac
    key=${line%%=*}
    val=${line#*=}
    if [ "$key" = "$line" ]; then
      fleet_warn "設定檔 $f:$n 不是 KEY=value,略過"
      continue
    fi
    # 去掉 key 前後空白(值不去,值可能刻意有空白)
    key=$(printf '%s' "$key" | tr -d '[:space:]')
    if ! printf '%s' "$key" | grep -qE '^FLEET_[A-Z0-9_]+$'; then
      fleet_warn "設定檔 $f:$n 的 key「${key}」不是 FLEET_ 開頭的大寫名稱,略過"
      continue
    fi
    case "$val" in
      *'`'* | *'$('*)
        fleet_warn "設定檔 $f:$n 的值含命令替換,拒絕載入"
        continue
        ;;
    esac
    # 去掉包住整個值的單引號或雙引號(常見寫法,不去會把引號當內容)
    case "$val" in
      \"*\") val=${val#\"}; val=${val%\"} ;;
      \'*\') val=${val#\'}; val=${val%\'} ;;
    esac
    # 有限度的家目錄展開:只認**開頭**的 ~/ 與 $HOME/。
    # 刻意不做一般變數展開——那等於把設定檔變回可執行程式碼,
    # 上面擋掉 $( ) 與反引號就白做了。其他情況請寫完整絕對路徑。
    case "$val" in
      '~') val="$HOME" ;;
      '$HOME') val="$HOME" ;;
      '~/'*) val="$HOME/${val#\~/}" ;;
      '$HOME/'*) val="$HOME/${val#\$HOME/}" ;;
    esac
    # 真實環境變數優先
    if eval "[ -n \"\${$key+x}\" ]"; then continue; fi
    eval "export $key=\$val"
  done < "$f"
}

# ---------------------------------------------------------------------------
# 執行期路徑(必須在 fleet_load_config 之後呼叫)
# ---------------------------------------------------------------------------

fleet_init_paths() {
  : "${FLEET_HOME:=${XDG_DATA_HOME:-$HOME/.local/share}/fleet}"
  : "${FLEET_PROFILE:=default}"
  : "${FLEET_REPORTS:=$HOME/fleet/reports}"
  : "${FLEET_TASKS:=$HOME/fleet/tasks}"
  : "${FLEET_DEFAULT_DIR:=$PWD}"
  : "${FLEET_SOCKET:=agents}"
  : "${FLEET_SESSION:=fleet}"
  : "${FLEET_SEND_DELAY:=1}"
  : "${FLEET_POLL_SECS:=3}"
  : "${FLEET_STABLE_SECS:=3}"
  : "${FLEET_IDLE_SECS:=90}"
  : "${FLEET_STUCK_SECS:=60}"
  : "${FLEET_QUIET_AFTER_REPORT:=300}"
  : "${FLEET_BACKFILL_SECS:=600}"
  : "${FLEET_MAX_ATTEMPTS:=3}"
  : "${FLEET_LINT_REPORTS:=1}"

  if ! printf '%s' "$FLEET_PROFILE" | grep -qE '^[A-Za-z0-9_-]+$'; then
    fleet_err "FLEET_PROFILE「${FLEET_PROFILE}」只能用英數 _ -"
    exit 1
  fi

  FLEET_PROFILE_DIR="$FLEET_HOME/profiles/$FLEET_PROFILE"
  FLEET_REG="$FLEET_PROFILE_DIR/registry"
  FLEET_COMMANDER_FILE="$FLEET_PROFILE_DIR/commander"
  FLEET_STATE_FILE="$FLEET_PROFILE_DIR/state.json"
  FLEET_LOG="$FLEET_PROFILE_DIR/watch.log"
  FLEET_PIDFILE="$FLEET_PROFILE_DIR/watch.pid"
  FLEET_LOCKDIR="$FLEET_PROFILE_DIR/locks"

  export FLEET_HOME FLEET_PROFILE FLEET_REPORTS FLEET_TASKS FLEET_DEFAULT_DIR
  export FLEET_SOCKET FLEET_SESSION FLEET_SEND_DELAY
  export FLEET_POLL_SECS FLEET_STABLE_SECS FLEET_IDLE_SECS FLEET_STUCK_SECS
  export FLEET_QUIET_AFTER_REPORT FLEET_BACKFILL_SECS FLEET_MAX_ATTEMPTS
  export FLEET_LINT_REPORTS
  export FLEET_PROFILE_DIR FLEET_REG FLEET_COMMANDER_FILE FLEET_STATE_FILE
  export FLEET_LOG FLEET_PIDFILE FLEET_LOCKDIR
}

fleet_ensure_dirs() {
  mkdir -p "$FLEET_PROFILE_DIR" "$FLEET_LOCKDIR" || return 1
  touch "$FLEET_REG" 2>/dev/null || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 顏色與訊息
# ---------------------------------------------------------------------------

# shellcheck disable=SC2034  # 這些顏色變數給 source 這個檔的腳本用,這裡看起來未使用
fleet_init_colors() {
  if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ] || [ "${TERM:-dumb}" = dumb ]; then
    c_red='' c_grn='' c_ylw='' c_cyn='' c_dim='' c_rst=''
  else
    c_red=$'\033[31m' c_grn=$'\033[32m' c_ylw=$'\033[33m'
    c_cyn=$'\033[36m' c_dim=$'\033[2m' c_rst=$'\033[0m'
  fi
}
fleet_init_colors

fleet_err()  { printf '%sfleet: %s%s\n' "$c_red" "$*" "$c_rst" >&2; }
fleet_warn() { printf '%sfleet: %s%s\n' "$c_ylw" "$*" "$c_rst" >&2; }
fleet_info() { printf '%s%s%s\n' "$c_cyn" "$*" "$c_rst"; }
fleet_die()  { fleet_err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# 結構化日誌(JSON Lines)
# ---------------------------------------------------------------------------

# 把一段文字轉成可放進 JSON 字串的內容。純 bash,不 fork python
# (watcher 每 3 秒跑一輪,每輪 fork 一次 python 只為了 log 太浪費)。
fleet_json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/\\r}
  s=${s//$'\n'/\\n}
  printf '%s' "$s"
}

# fleet_log <level> <event> [key=value ...]
# 輸出一行 JSON 到 $FLEET_LOG。key 只接受 [A-Za-z0-9_],值一律當字串。
fleet_log() {
  local level=$1 event=$2 kv k v out
  shift 2
  out=$(printf '{"ts":"%s","level":"%s","event":"%s"' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    "$(fleet_json_escape "$level")" \
    "$(fleet_json_escape "$event")")
  for kv in "$@"; do
    k=${kv%%=*}
    v=${kv#*=}
    printf '%s' "$k" | grep -qE '^[A-Za-z0-9_]+$' || continue
    out="$out,\"$k\":\"$(fleet_json_escape "$v")\""
  done
  out="$out}"
  [ -n "${FLEET_LOG:-}" ] || { printf '%s\n' "$out" >&2; return 0; }
  printf '%s\n' "$out" >> "$FLEET_LOG" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 原子鎖(mkdir 是 bash 唯一可攜的原子 CAS;macOS 沒有 flock)
# ---------------------------------------------------------------------------

# fleet_lock <名稱> — 取到回 0,已被佔用回 1。非等待式。
fleet_lock() {
  local name=$1
  mkdir "$FLEET_LOCKDIR/$name.lock" 2>/dev/null
}
fleet_unlock() {
  local name=$1
  rmdir "$FLEET_LOCKDIR/$name.lock" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 跨平台小工具
# ---------------------------------------------------------------------------

# 檔案 mtime(epoch 秒)。BSD stat 與 GNU stat 旗標不同。
fleet_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

fleet_md5() {
  md5 -q "$1" 2>/dev/null || md5sum "$1" 2>/dev/null | cut -d' ' -f1 || echo ""
}

fleet_now() { date +%s; }

# 家目錄前綴換成 ~。
# 不用 ${path/#$HOME/\~}:那個 \ 會被當成字面反斜線留在輸出裡(顯示成 \~)。
fleet_tildify() {
  local p=$1 rest
  rest=${p#"$HOME"}
  if [ "$rest" != "$p" ]; then
    printf '~%s' "$rest"
  else
    printf '%s' "$p"
  fi
}

# 把任意字串包成單引號形式,可安全貼進 sh 命令列。
# 路徑含空白或引號時,沒跳脫的輸出貼進終端就是語法錯誤。
fleet_shq() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}
