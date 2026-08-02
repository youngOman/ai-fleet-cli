# shellcheck shell=bash
# tmuxio.sh — 對 TUI pane 送訊息與讀畫面
#
# 這個檔案裡每一步都是踩過坑才加的,**一條都不能少**。刪任何一行之前,
# 先去讀 docs/pitfalls.md 對應那一條。

[ -n "${_FLEET_TMUXIO_LOADED:-}" ] && return 0
_FLEET_TMUXIO_LOADED=1

# pane_capture <socket> <pane> [行數]
pane_capture() {
  local sock=$1 pane=$2 lines=${3:-0}
  if [ "$lines" -gt 0 ] 2>/dev/null; then
    stmux "$sock" capture-pane -p -t "$pane" -S -"$lines" 2>/dev/null || true
  else
    stmux "$sock" capture-pane -p -t "$pane" 2>/dev/null || true
  fi
}

# pane 是否在 copy-mode(使用者正在捲動 / 選字)
pane_in_mode() {
  local sock=$1 pane=$2 v
  v=$(stmux "$sock" display-message -p -t "$pane" '#{pane_in_mode}' 2>/dev/null || echo 0)
  [ "$v" = "1" ]
}

# TUI 起來了沒。前景若還是 shell,表示 TUI 沒起來或正在重啟。
tui_ready() {
  local sock=$1 pane=$2 cmd
  cmd=$(stmux "$sock" display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null || echo '')
  case "$cmd" in
    '' | zsh | bash | sh | fish | dash | login) return 1 ;;
    *) return 0 ;;
  esac
}

# composer_busy_content <內容> [kind]
# 使用者正在打字就回 0(真)。kind 給空字串時用泛用規則。
composer_busy_content() {
  local content=$1 kind=${2:-} re='' ign='' hits
  if [ -n "$kind" ]; then
    re=$(signals_get "$kind" composer 2>/dev/null || true)
    ign=$(signals_get "$kind" composer_ignore 2>/dev/null || true)
  fi
  # 泛用規則要同時涵蓋兩種提示符:claude 是 ❯,codex 是 ›(U+203A)。
  [ -n "$re" ] || re='❯[[:space:]]+[^[:space:]]|›[[:space:]]+[^[:space:]]'

  # 有排隊訊息一律不插隊
  printf '%s' "$content" | LC_ALL=C grep -qE 'Press up to edit queued' && return 0

  hits=$(printf '%s' "$content" | LC_ALL=C grep -E "$re")
  [ -n "$hits" ] || return 1

  # composer_ignore:輸入框裡的灰字提示不是使用者打的字。
  # 全部命中白名單就代表輸入框其實是空的。
  if [ -n "$ign" ]; then
    hits=$(printf '%s' "$hits" | LC_ALL=C grep -vE "$ign")
  fi
  [ -n "$hits" ]
}

# ---------------------------------------------------------------------------
# send_verified <socket> <pane> <訊息> <短單號> [kind]
# ---------------------------------------------------------------------------
# 回傳碼:
#   0  已送出且回讀驗證到單號
#   1  送出了但驗不到(呼叫端要記一次 attempt,達上限就熔斷)
#   2  使用者正在打字 → 不送、**不記帳**(下輪再試,通知不會遺失)
#   3  TUI 沒起來 → 不送、**不記帳**
send_verified() {
  local sock=$1 pane=$2 msg=$3 tag=$4 kind=${5:-}
  local screen

  # 1. copy-mode 會把 send-keys 整包吃掉,先退出來
  if pane_in_mode "$sock" "$pane"; then
    stmux "$sock" send-keys -t "$pane" -X cancel 2>/dev/null || true
  fi

  # 2. 前景是 shell → 這輪不送也不記帳
  tui_ready "$sock" "$pane" || return 3

  # 3. 使用者正在打字 → 絕對不插隊
  screen=$(pane_capture "$sock" "$pane" 8)
  if composer_busy_content "$screen" "$kind"; then
    return 2
  fi

  # 4. literal 貼字
  stmux "$sock" send-keys -t "$pane" -l -- "$msg" 2>/dev/null || return 1

  # 5. TUI composer 收字有延遲,貼完立刻按 Enter 會按在空框上
  sleep "${FLEET_SEND_DELAY:-1}"

  # 6. 獨立送一個 Enter
  stmux "$sock" send-keys -t "$pane" Enter 2>/dev/null || return 1

  # 7. 回讀驗證。**只 grep 短單號**——長句會被 TUI 折行,grep 全文必定失敗。
  sleep 1
  if pane_capture "$sock" "$pane" 150 | LC_ALL=C grep -qF "$tag"; then
    return 0
  fi
  return 1
}

# send_plain <socket> <pane> <訊息>
# 給 `fleet send` 用的互動路徑:多行內容走 bracketed paste,不做回讀驗證
# (使用者當下就在看畫面,驗證交給他的眼睛;而且長 ticket 沒有短單號可 grep)。
send_plain() {
  local sock=$1 pane=$2 text=$3
  if pane_in_mode "$sock" "$pane"; then
    stmux "$sock" send-keys -t "$pane" -X cancel 2>/dev/null || true
  fi
  printf '%s' "$text" | stmux "$sock" load-buffer -b fleet_tk - || return 1
  stmux "$sock" paste-buffer -b fleet_tk -t "$pane" -p -d || return 1
  sleep 0.4
  stmux "$sock" send-keys -t "$pane" Enter
}
