# shellcheck shell=bash
# signals.sh — 從 adapters/*.conf 讀訊號規則,提供狀態判定
#
# 唯一的 regex 來源。任何地方要判斷「這個 pane 在忙嗎 / 卡住了嗎」都走這裡,
# 不可以再複製一份 regex 出去。

[ -n "${_FLEET_SIGNALS_LOADED:-}" ] && return 0
_FLEET_SIGNALS_LOADED=1

: "${FLEET_ADAPTER_DIR:=$FLEET_LIBDIR/adapters}"

# 列出所有可用的 kind
signals_kinds() {
  local f b
  for f in "$FLEET_ADAPTER_DIR"/*.conf; do
    [ -f "$f" ] || continue
    b=$(basename "$f" .conf)
    printf '%s\n' "$b"
  done
}

# bash 3.2 沒有關聯陣列,用「合法變數名」模擬:_ADP_<kind>_<key>
# kind 與 key 都先驗證過字元集,所以 eval 是安全的。
signals_load() {
  # shellcheck disable=SC2034  # val 是在下面的 eval 字串裡用的,shellcheck 看不到
  local kind=$1 f line key val
  printf '%s' "$kind" | grep -qE '^[a-z0-9_]+$' || return 1
  eval "[ -n \"\${_ADP_LOADED_$kind:-}\" ]" && return 0
  f="$FLEET_ADAPTER_DIR/$kind.conf"
  [ -f "$f" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '' | '#'*) continue ;; esac
    key=${line%%=*}
    # shellcheck disable=SC2034  # val 由下面的 eval 展開使用
    val=${line#*=}
    [ "$key" = "$line" ] && continue
    printf '%s' "$key" | grep -qE '^[a-z0-9_]+$' || continue
    eval "_ADP_${kind}_${key}=\$val"
  done < "$f"
  eval "_ADP_LOADED_$kind=1"
  return 0
}

# signals_get <kind> <key> — 取不到就回空字串
signals_get() {
  local kind=$1 key=$2
  signals_load "$kind" || return 1
  eval "printf '%s' \"\${_ADP_${kind}_${key}:-}\""
}

# ---------------------------------------------------------------------------
# 比對
# ---------------------------------------------------------------------------
# 一律 LC_ALL=C:worker 畫面含大量 UTF-8 框線與 emoji,macOS 的 grep 在
# UTF-8 locale 下遇到非法位元組序列會直接噴 illegal byte sequence 並失敗
# ——失敗會被當成「不符合」,於是忙碌中的 worker 被誤判成閒置。
# adapters/*.conf 因此禁止使用多位元組字元集(見該檔頭)。

# signals_match <kind> <key> <內容>
signals_match() {
  local kind=$1 key=$2 content=$3 re
  re=$(signals_get "$kind" "$key") || return 1
  [ -n "$re" ] || return 1
  printf '%s' "$content" | LC_ALL=C grep -qE "$re"
}

pane_busy()   { signals_match "$1" busy "$2"; }
pane_stuck()  { signals_match "$1" stuck "$2"; }
pane_asking() { signals_match "$1" asking "$2"; }
pane_ready()  { signals_match "$1" ready "$2"; }
pane_trust()  { signals_match "$1" trust "$2"; }

# 使用者正在打字?composer 行(❯ 開頭)後面有非空白字元就是。
# **使用者打字時絕對不能注入。** 實案:通知直接插進使用者打到一半的句子,
# 把「共享」洗成「共」+通知+「享」,使用者根本沒辦法跟指揮官講話。
pane_composer_busy() {
  local kind=$1 content=$2 re
  re=$(signals_get "$kind" composer)
  [ -n "$re" ] || re='❯[[:space:]]+[^[:space:]]'
  printf '%s' "$content" | LC_ALL=C grep -qE "$re|Press up to edit queued"
}

# 從畫面內容判斷是哪一種 CLI。全部 adapter 都比一輪,第一個中的就算。
# 回傳 kind;都不中就回空字串並 return 1。
detect_kind() {
  local content=$1 kind
  for kind in $(signals_kinds); do
    if signals_match "$kind" detect "$content"; then
      printf '%s' "$kind"
      return 0
    fi
  done
  return 1
}

# 依序回傳這個 adapter 定義的自動應答規則:每行 `match<TAB>keys`
signals_autoreplies() {
  local kind=$1 n=1 m k
  signals_load "$kind" || return 0
  while [ "$n" -le 9 ]; do
    m=$(eval "printf '%s' \"\${_ADP_${kind}_autoreply${n}_match:-}\"")
    k=$(eval "printf '%s' \"\${_ADP_${kind}_autoreply${n}_keys:-}\"")
    [ -n "$m" ] && [ -n "$k" ] && printf '%s\t%s\n' "$m" "$k"
    n=$((n + 1))
  done
}
