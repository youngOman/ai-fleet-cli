# ---------------------------------------------------------------------------
# fleet — zsh 補全
#
# 安裝方式：在 ~/.zshrc 的 compinit 之後 source 本檔
#   autoload -Uz compinit && compinit
#   source /path/to/completion/fleet.zsh
#
# （刻意不加 #compdef 標頭：本檔是「被 source」的形式，
#   檔尾自己呼叫 compdef 註冊，放進 $fpath 當 autoload 檔會壞掉。）
#
# 設計原則：
#   - 子指令一律帶中文說明（搭配 fzf-tab 會變成有說明的下拉選單）
#   - worker id 動態從 registry 抓，**不硬編任何預設 id**；讀不到就給空候選
#   - 一律用陣列傳遞候選，檔名/路徑含空白也安全
# ---------------------------------------------------------------------------

# 依 docs/ARCHITECTURE.md 第 2 節推導出當前 profile 目錄
#   $FLEET_HOME/profiles/$FLEET_PROFILE
#   FLEET_HOME 預設 ${XDG_DATA_HOME:-$HOME/.local/share}/fleet
_fleet_profile_dir() {
  local base="${FLEET_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/fleet}"
  print -r -- "${base}/profiles/${FLEET_PROFILE:-default}"
}

# 所有 profile 的共同父目錄
_fleet_profiles_root() {
  local base="${FLEET_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/fleet}"
  print -r -- "${base}/profiles"
}

# worker id：registry 第 1 欄（格式 id<TAB>socket<TAB>pane<TAB>kind）
_fleet_workers() {
  local reg id rest
  local -a ids
  reg="$(_fleet_profile_dir)/registry"
  if [[ -r "$reg" ]]; then
    # 用 while read 而非 cut，避免 id 含空白時被 word split
    while IFS=$'\t' read -r id rest || [[ -n "$id" ]]; do
      if [[ -n "$id" && "$id" != '#'* ]]; then
        ids+=("$id")
      fi
    done < "$reg"
  fi
  # 讀不到 registry 或沒有 worker → 空候選（不猜、不硬編）
  (( ${#ids} )) || return 1
  _describe -t fleet-workers 'worker' ids
}

# 派工單：$FLEET_TASKS 下的 *.md，去掉副檔名
_fleet_tasks() {
  local dir="${FLEET_TASKS:-$HOME/fleet/tasks}"
  local -a names
  names=( "$dir"/*.md(N:t:r) )   # N=nullglob, :t=basename, :r=去副檔名
  (( ${#names} )) || return 1
  _describe -t fleet-tasks '派工單' names
}

# 報告：$FLEET_REPORTS 下的 *.md（保留副檔名，lint 吃檔名）
_fleet_reports() {
  local dir="${FLEET_REPORTS:-$HOME/fleet/reports}"
  local -a names
  names=( "$dir"/*.md(N:t) )
  (( ${#names} )) || return 1
  _describe -t fleet-reports '報告' names
}

# profile：profiles 目錄下的子目錄名
_fleet_profiles() {
  local root
  local -a names
  root="$(_fleet_profiles_root)"
  names=( "$root"/*(N/:t) )      # /=只要目錄
  (( ${#names} )) || return 1
  _describe -t fleet-profiles 'profile' names
}

_fleet_watch_actions() {
  local -a acts
  acts=(
    'start:啟動回報閉環 watcher'
    'stop:停止 watcher'
    'restart:重啟 watcher'
    'status:顯示 watcher 狀態與 pid'
    'log:追蹤 watch.log'
  )
  _describe -t fleet-watch-actions '動作' acts
}

_fleet_kinds() {
  local -a kinds
  kinds=(
    'cc:claude adapter'
    'cx:codex adapter'
  )
  _describe -t fleet-kinds 'adapter 種類' kinds
}

_fleet_up_flags() {
  _arguments \
    '--cc[以 claude adapter 開一個 worker]' \
    '--cx[以 codex adapter 開一個 worker]' \
    '-C[指定工作目錄]:工作目錄:_files -/'
}

# 依子指令切換候選集
_fleet_subcmd_args() {
  case "${words[1]}" in
    send|peek|who|rename|forget|wait)
      _fleet_workers
      ;;
    task)
      case $CURRENT in
        2) _fleet_workers ;;
        3) _fleet_tasks ;;
        *) return 1 ;;
      esac
      ;;
    watch)
      if (( CURRENT == 2 )); then
        _fleet_watch_actions
      else
        return 1
      fi
      ;;
    lint)
      _fleet_reports
      ;;
    profile)
      _fleet_profiles
      ;;
    up)
      _fleet_up_flags
      ;;
    add)
      _fleet_kinds
      ;;
    *)
      return 1
      ;;
  esac
}

_fleet() {
  local curcontext="$curcontext" state line ret=1
  typeset -A opt_args

  local -a subcmds
  subcmds=(
    'mon:即時看板（艦隊狀態總覽）'
    'doctor:環境自我診斷（tmux / python3 / 路徑 / 設定）'
    'discover:掃描 tmux pane，找出可納管的 AI worker'
    'adopt:把既有 pane 納管成 worker'
    'who:顯示 worker 的身分與所在 pane'
    'rename:替 worker 改名'
    'forget:從 registry 移除 worker（不關 pane）'
    'ls:列出目前艦隊所有 worker'
    'up:開新 pane 並啟動一個 worker'
    'add:把指定種類的 worker 加入艦隊'
    'attach:切換到指定 worker 的 pane'
    'down:關閉 worker'
    'send:送一則訊息給 worker（含回讀驗證）'
    'bcast:廣播訊息給所有 worker'
    'task:派一張派工單給 worker'
    'peek:預覽 worker 的畫面內容'
    'wait:等待 worker 進入閒置'
    'reports:列出報告目錄內容'
    'lint:驗證報告是否符合四節 schema'
    'watch:回報閉環守護行程（start/stop/restart/status/log）'
    'commander:設定或顯示指揮官所在的 socket 與 pane'
    'profile:切換或列出艦隊 profile'
    'gc:清掉失效的報告與 worker 狀態'
    'config:顯示目前生效的設定與來源'
    'version:顯示版本'
    'help:顯示說明'
  )

  _arguments -C \
    '1: :->subcmd' \
    '*:: :->args' && ret=0

  case "$state" in
    subcmd)
      _describe -t fleet-commands 'fleet 子指令' subcmds && ret=0
      ;;
    args)
      _fleet_subcmd_args && ret=0
      ;;
  esac

  return ret
}

compdef _fleet fleet
