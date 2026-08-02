# ---------------------------------------------------------------------------
# fleet — bash 補全
#
# 安裝方式：在 ~/.bashrc 加
#   source /path/to/completion/fleet.bash
#
# 相容性：目標是 macOS 內建的 bash 3.2
#   → 不用 mapfile、不用 declare -A、不用 ${var,,}
#
# 功能對齊 completion/fleet.zsh（差別只在 bash 沒有描述文字）
# ---------------------------------------------------------------------------

# 候選集共用暫存（bash 3.2 沒有 nameref，只能用全域陣列傳遞）
_fleet_cands=()

# 依 docs/ARCHITECTURE.md 第 2 節推導出當前 profile 目錄
_fleet_profile_dir() {
    local base="${FLEET_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/fleet}"
    printf '%s/profiles/%s\n' "$base" "${FLEET_PROFILE:-default}"
}

_fleet_profiles_root() {
    local base="${FLEET_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/fleet}"
    printf '%s/profiles\n' "$base"
}

# worker id：registry 第 1 欄（id<TAB>socket<TAB>pane<TAB>kind）
# 讀不到檔案就留空候選，不硬編任何預設 id
_fleet_worker_ids() {
    local reg id rest
    _fleet_cands=()
    reg="$(_fleet_profile_dir)/registry"
    [ -r "$reg" ] || return 0
    while IFS=$'\t' read -r id rest || [ -n "$id" ]; do
        case "$id" in
            ''|'#'*) continue ;;
        esac
        _fleet_cands[${#_fleet_cands[@]}]="$id"
    done < "$reg"
}

# 派工單：$FLEET_TASKS 下的 *.md，去掉副檔名
_fleet_task_names() {
    local dir="${FLEET_TASKS:-$HOME/fleet/tasks}" f base
    _fleet_cands=()
    for f in "$dir"/*.md; do
        [ -e "$f" ] || continue
        base="${f##*/}"
        _fleet_cands[${#_fleet_cands[@]}]="${base%.md}"
    done
}

# 報告：$FLEET_REPORTS 下的 *.md（保留副檔名）
_fleet_report_names() {
    local dir="${FLEET_REPORTS:-$HOME/fleet/reports}" f
    _fleet_cands=()
    for f in "$dir"/*.md; do
        [ -e "$f" ] || continue
        _fleet_cands[${#_fleet_cands[@]}]="${f##*/}"
    done
}

# profile：profiles 目錄下的子目錄名
_fleet_profile_names() {
    local root d base
    _fleet_cands=()
    root="$(_fleet_profiles_root)"
    for d in "$root"/*/; do
        [ -d "$d" ] || continue
        d="${d%/}"
        base="${d##*/}"
        _fleet_cands[${#_fleet_cands[@]}]="$base"
    done
}

# 以 $1 為前綴過濾 _fleet_cands，結果寫進 COMPREPLY
# 逐一比對而不用 compgen -W，避免候選含空白時被字串拼接切碎
_fleet_filter() {
    local cur="$1" c n=0
    COMPREPLY=()
    for c in "${_fleet_cands[@]}"; do
        case "$c" in
            "$cur"*)
                # 含空白的候選要跳脫，否則插回命令列會被當成兩個參數
                COMPREPLY[$n]="${c// /\\ }"
                n=$((n + 1))
                ;;
        esac
    done
}

_fleet() {
    local cur cmd
    COMPREPLY=()
    _fleet_cands=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    cmd="${COMP_WORDS[1]}"

    if [ "$COMP_CWORD" -eq 1 ]; then
        _fleet_cands=(
            mon doctor discover adopt who rename forget ls up add attach down
            send bcast task peek wait reports lint watch commander profile gc
            config version help
        )
    else
        case "$cmd" in
            send|peek|who|rename|forget|wait)
                _fleet_worker_ids
                ;;
            task)
                if [ "$COMP_CWORD" -eq 2 ]; then
                    _fleet_worker_ids
                elif [ "$COMP_CWORD" -eq 3 ]; then
                    _fleet_task_names
                fi
                ;;
            watch)
                if [ "$COMP_CWORD" -eq 2 ]; then
                    _fleet_cands=(start stop restart status log)
                fi
                ;;
            lint)
                _fleet_report_names
                ;;
            profile)
                _fleet_profile_names
                ;;
            up)
                _fleet_cands=(--cc --cx -C)
                ;;
            add)
                _fleet_cands=(cc cx)
                ;;
            *)
                ;;
        esac
    fi

    _fleet_filter "$cur"
    return 0
}

complete -F _fleet fleet
