# shellcheck shell=bash
# registry.sh — worker 登記表讀寫
#
# 格式:每列 4 欄,TAB 分隔
#   id <TAB> socket <TAB> pane <TAB> kind
#
#   socket  `-` = 預設 socket(使用者日常那個);其他值 = 具名 socket(tmux -L <值>)
#   pane    一律是 tmux 穩定 pane id(%NN)。
#           **不接受 `session:win.pane` 座標**——座標會因為別人插一格而整排位移,
#           導致派工送錯人。舊版 spawn 路徑就是漏了這條,寫進了 `fleet:cc1`。
#   kind    對應 adapters/<kind>.conf 的檔名

[ -n "${_FLEET_REGISTRY_LOADED:-}" ] && return 0
_FLEET_REGISTRY_LOADED=1

reg_get()  { awk -F'\t' -v id="$1" '$1==id{print; f=1} END{exit !f}' "$FLEET_REG"; }
reg_ids()  { awk -F'\t' 'NF{print $1}' "$FLEET_REG"; }
reg_count() { awk -F'\t' 'NF{n++} END{print n+0}' "$FLEET_REG"; }

wsocket() { reg_get "$1" | cut -f2; }
wpane()   { reg_get "$1" | cut -f3; }
wkind()   { reg_get "$1" | cut -f4; }

# registry 是多寫入者共用的檔(fleet adopt / fleet forget / watcher 都會碰)。
# 沒有鎖的 `awk > tmp && mv` 在併發時會靜默丟 entry。
_reg_write_locked() {
  local i=0
  while ! fleet_lock registry; do
    i=$((i + 1))
    [ "$i" -gt 50 ] && { fleet_err "registry 鎖等待逾時(可手動 rmdir $FLEET_LOCKDIR/registry.lock)"; return 1; }
    sleep 0.1
  done
  "$@"
  local rc=$?
  fleet_unlock registry
  return $rc
}

_reg_del_raw() {
  local id=$1 tmp="$FLEET_REG.tmp.$$"
  awk -F'\t' -v id="$id" '$1!=id' "$FLEET_REG" > "$tmp" && mv "$tmp" "$FLEET_REG"
}

_reg_add_raw() {
  local id=$1 sock=$2 pane=$3 kind=$4 tmp="$FLEET_REG.tmp.$$"
  awk -F'\t' -v id="$id" '$1!=id' "$FLEET_REG" > "$tmp" || return 1
  printf '%s\t%s\t%s\t%s\n' "$id" "$sock" "$pane" "$kind" >> "$tmp" || return 1
  mv "$tmp" "$FLEET_REG"
}

reg_del() { _reg_write_locked _reg_del_raw "$1"; }
reg_add() { _reg_write_locked _reg_add_raw "$1" "$2" "$3" "$4"; }

# ---------------------------------------------------------------------------
# 驗證
# ---------------------------------------------------------------------------

# **不要用 grep 做這種驗證。** grep 是逐行比對的:`printf '%s' "%1
# %2" | grep -qE '^%[0-9]+$'` 會因為第一行符合而回 0,含換行的值就這樣通過驗證,
# 接著被 `printf '%s\t...\n'` 寫成 registry 的兩列,第二列是半截資料,
# `reg_ids` 又會把它當成真的 worker id ——幽靈 worker 就是這樣長出來的。
# 用 case 做整串比對(順帶省掉每次驗證 fork 一個 grep)。

valid_id() {
  case "$1" in
    '' | *[!A-Za-z0-9_-]*) return 1 ;;
    *) return 0 ;;
  esac
}

valid_socket() {
  [ "$1" = "-" ] && return 0
  valid_id "$1"
}

# 只收 %NN。這是刻意的嚴格——見檔頭說明。
valid_pane() {
  local n=${1#%}
  [ "$n" != "$1" ] || return 1      # 沒有開頭的 %
  case "$n" in
    '' | *[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# ---------------------------------------------------------------------------
# 對某個 worker 執行 tmux(自動帶對的 -L socket)
# ---------------------------------------------------------------------------

# stmux <socket> <tmux 參數...>
stmux() {
  local s=$1
  shift
  if [ "$s" = "-" ] || [ -z "$s" ]; then
    tmux "$@"
  else
    tmux -L "$s" "$@"
  fi
}

# wtmux <worker id> <tmux 參數...>
wtmux() {
  local id=$1
  shift
  stmux "$(wsocket "$id")" "$@"
}

# pane_exists <socket> <pane>
#
# **不要用 `display-message -p -t <pane>` 的離開碼判斷 pane 存不存在。**
# 實測 tmux 3.7b:對不存在的 pane 它回**離開碼 0 加上空輸出**,
# 於是「pane 還活著」的檢查對已關閉的 pane 一律回真——派工會送進虛空,
# 而且看板永遠不會顯示失聯。必須比對輸出內容。
pane_exists() {
  local sock=$1 pane=$2 out
  [ -n "$pane" ] || return 1
  out=$(stmux "$sock" display-message -p -t "$pane" '#{pane_id}' 2>/dev/null) || return 1
  [ "$out" = "$pane" ]
}

pane_alive() {
  local id=$1
  pane_exists "$(wsocket "$id")" "$(wpane "$id")"
}

require_worker() {
  reg_get "$1" >/dev/null 2>&1 \
    || fleet_die "worker「$1」未登記。用 fleet ls 看清單,fleet discover 找現有 pane。"
  pane_alive "$1" \
    || fleet_die "worker「$1」的 pane 不見了(可能已關)。用 fleet forget $1 清掉登記。"
}

# ---------------------------------------------------------------------------
# 指揮官(兩欄:socket <TAB> pane)
# ---------------------------------------------------------------------------
# 舊版只存一欄 pane 並且通知一律用裸 tmux,指揮官若不在預設 socket 就全部靜默失敗。

commander_socket() {
  [ -f "$FLEET_COMMANDER_FILE" ] || return 1
  # 舊格式是單欄(只有 pane),視為預設 socket
  awk -F'\t' 'NR==1{print (NF>=2 ? $1 : "-")}' "$FLEET_COMMANDER_FILE"
}

commander_pane() {
  [ -f "$FLEET_COMMANDER_FILE" ] || return 1
  awk -F'\t' 'NR==1{print (NF>=2 ? $2 : $1)}' "$FLEET_COMMANDER_FILE"
}

commander_set() {
  local pane=$1 sock=${2:--}
  valid_pane "$pane" || { fleet_err "指揮官 pane 要是 %NN 形式(tmux display -p '#{pane_id}' 可查)"; return 1; }
  valid_socket "$sock" || { fleet_err "socket 名怪異,拒絕"; return 1; }
  printf '%s\t%s\n' "$sock" "$pane" > "$FLEET_COMMANDER_FILE"
}
