#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install.sh — ai-fleet-cli 安裝器
# ---------------------------------------------------------------------------
#
# 相容目標:bash 3.2(macOS 內建的 /bin/bash)。
# 不可使用關聯陣列、${var,,}、mapfile、declare -A。
#
# ⚠ bash 3.2 的中文坑:變數展開後面**直接**接非 ASCII 字元(例如 $ 加 name 再接「」),
#   在 set -u 下直接噴 `var\xe5: unbound variable` 整支腳本當場死掉。
#   **變數後面只要接非 ASCII 字元,一律寫成 `${var}中文`。**
#
# 三條紅線
# --------
# 1. **絕不修改使用者的 shell rc**(.bashrc / .zshrc / .profile 一律不碰)。
#    PATH 與補全設定改為印出可直接複製貼上的指令。
#    理由:自動改 rc 省下的只是使用者貼一行 export,換來的卻是一整類
#    會動到家目錄設定檔的失效路徑——寫錯位置(Debian .bashrc 前段會
#    early return)、重複附加、rc 語法被弄壞導致所有新終端都開不起來、
#    使用者用的是 fish/nu 而我們猜成 bash、rc 由 chezmoi/stow 管理而被
#    下次同步覆寫回去。這些壞掉的樣子全都與 fleet 無關,但都會算在 fleet 頭上,
#    而且使用者很難自己判斷是誰改的。省一行貼上不值得。
#
# 2. **內容不同才備份,備份檔名不重用,備份失敗即中止**。
#    用 cmp -s 比對:相同就不動(不然重跑一次安裝就多一堆同內容備份,
#    真正有價值的那份反而被淹掉)。備份名 <檔>.bak-<時間戳>,已存在就加序號
#    (同一秒內跑兩次不會互相覆寫)。cp 失敗直接 exit 1——備份不成功卻繼續覆寫,
#    等於在使用者不知情的狀況下毀掉他改過的檔案。
#
# 3. **驗證安裝要看離開碼,不只看 executable bit**。
#    語法錯誤的腳本一樣有 x bit;裝完要實跑 `fleet version` 並檢查離開碼。
#
# 另外刻意不做的事:**缺相依不自動安裝**。這是公開工具,擅自跑 brew/apt-get
# 太侵入(會動到 sudo、會裝進使用者沒預期的地方),改為印出該平台的安裝指令。
# ---------------------------------------------------------------------------

set -eu

# ---------------------------------------------------------------------------
# 基本設定
# ---------------------------------------------------------------------------

REQ_TMUX_MAJOR=3
REQ_TMUX_MINOR=0
REQ_PY_MAJOR=3
REQ_PY_MINOR=8

# 從來源複製到 PREFIX 的目錄。required=缺了就中止。
REQUIRED_DIRS="bin lib libexec adapters"
OPTIONAL_DIRS="share completion"

MODE=install
DRY_RUN=0

COPIED=0
SKIPPED=0
BACKED=0

LOCK_DIR=""

# ---------------------------------------------------------------------------
# 訊息
# ---------------------------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'
  C_CYN=$'\033[36m'; C_DIM=$'\033[2m';  C_RST=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YLW=''; C_CYN=''; C_DIM=''; C_RST=''
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s%s%s\n' "$C_CYN" "$*" "$C_RST"; }
good() { printf '%s✓%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s⚠%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
err()  { printf '%s✗%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
die()  { err "$*"; exit 1; }
step() { printf '\n%s== %s ==%s\n' "$C_DIM" "$*" "$C_RST"; }

# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------

# 解析 symlink 鏈,回傳最終檔案所在目錄。
# 與 lib/core.sh 的 fleet_resolve_dir 同一套演算法;這裡必須內嵌一份,
# 因為要先找到自己在哪才能找到 lib/。不用 readlink -f:舊版 BSD 沒有 -f。
self_dir() {
  local p=$1 d
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

# POSIX 單引號跳脫:把任意字串包成一個可安全貼進 shell 的字面值。
shq() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# 給人複製貼上的路徑寫法。家目錄底下且字元單純 → 寫成 "$HOME/..."
# (可讀、換機器也對);其他一律 shq(路徑含空白時唯一安全的寫法)。
pretty_path() {
  local p=$1 rest
  case "$p" in
    "$HOME"/*)
      rest=${p#"$HOME"/}
      case "$rest" in
        *[!A-Za-z0-9._/-]*) shq "$p" ;;
        *) printf '"$HOME/%s"' "$rest" ;;
      esac
      ;;
    *) shq "$p" ;;
  esac
}

# 目錄是否已在 PATH 上(逐段精確比對,不用 case 比對子字串)
in_path() {
  local want=$1 p
  local IFS=:
  for p in $PATH; do
    [ -n "$p" ] || p=.
    if [ "$p" = "$want" ]; then return 0; fi
  done
  return 1
}

# 列出 PATH 上所有同名可執行檔(找衝突用)。
# PATH 上同一個目錄重複出現是很常見的(rc 被 source 兩次),要去重,
# 不然會報「有 3 個 fleet」但其實是同一個檔。
all_in_path() {
  local name=$1 p seen=''
  local IFS=:
  for p in $PATH; do
    [ -n "$p" ] || p=.
    case "$seen" in *":$p:"*) continue ;; esac
    seen="$seen:$p:"
    if [ -x "$p/$name" ] && [ ! -d "$p/$name" ]; then
      printf '%s\n' "$p/$name"
    fi
  done
  return 0
}

# ver_ge <有的major> <有的minor> <要的major> <要的minor>
ver_ge() {
  if [ "$1" -gt "$3" ]; then return 0; fi
  if [ "$1" -eq "$3" ] && [ "$2" -ge "$4" ]; then return 0; fi
  return 1
}

# 依這台機器實際有的套件管理器,印出安裝指令
pkg_hint() {
  local pkg=$1
  if command -v brew >/dev/null 2>&1; then
    printf 'brew install %s' "$pkg"
  elif command -v apt-get >/dev/null 2>&1; then
    printf 'sudo apt-get update && sudo apt-get install -y %s' "$pkg"
  elif command -v dnf >/dev/null 2>&1; then
    printf 'sudo dnf install -y %s' "$pkg"
  elif command -v pacman >/dev/null 2>&1; then
    printf 'sudo pacman -S --needed %s' "$pkg"
  else
    printf '(找不到已知的套件管理器)請自行安裝 %s' "$pkg"
  fi
}

# 執行一個動作;--dry-run 時只印不做
run() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '  %s[dry-run]%s %s\n' "$C_DIM" "$C_RST" "$*"
    return 0
  fi
  "$@"
}

# 「已完成」訊息。dry-run 時什麼都沒做,印 ✓ 會讓人以為真的裝好了。
did() {
  [ "$DRY_RUN" = 1 ] && return 0
  good "$@"
}

# ---------------------------------------------------------------------------
# 安裝鎖(mkdir 是可攜的原子 CAS;macOS 沒有 flock)
# ---------------------------------------------------------------------------
# 擋的是「同一台機器同時跑兩次安裝」——兩邊會交錯覆寫同一批檔案,
# 而且互相把對方寫到一半的檔案備份起來,備份內容變成垃圾。

cleanup() {
  if [ -n "$LOCK_DIR" ] && [ -d "$LOCK_DIR" ]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

take_lock() {
  local root=$1 d="$1/.fleet-install.lock"
  if [ "$DRY_RUN" = 1 ]; then
    say "  ${C_DIM}[dry-run]${C_RST} 取得安裝鎖 $d"
    return 0
  fi
  mkdir -p "$root" || die "無法建立 $root"
  if ! mkdir "$d" 2>/dev/null; then
    err "另一個安裝程序正在使用 $root"
    err "鎖目錄:$d"
    die "若確定沒有其他安裝在跑,手動移除:rmdir $(shq "$d")"
  fi
  LOCK_DIR=$d
}

# ---------------------------------------------------------------------------
# 檔案安裝(紅線 2)
# ---------------------------------------------------------------------------

backup_path() {
  local dst=$1 base cand n ts
  ts=$(date +%Y%m%d-%H%M%S)
  base="$dst.bak-$ts"
  cand=$base
  n=1
  # 同一秒內跑兩次也不會重用檔名
  while [ -e "$cand" ]; do
    cand="$base-$n"
    n=$((n + 1))
  done
  printf '%s' "$cand"
}

install_file() {
  local src=$1 dst=$2 bak dstdir
  dstdir=$(dirname "$dst")

  if [ -e "$dst" ]; then
    if cmp -s "$src" "$dst"; then
      SKIPPED=$((SKIPPED + 1))
      return 0
    fi
    bak=$(backup_path "$dst")
    if [ "$DRY_RUN" = 1 ]; then
      printf '  %s[dry-run]%s 備份 %s → %s\n' "$C_DIM" "$C_RST" "$dst" "$bak"
    else
      cp -p "$dst" "$bak" || die "備份失敗:$dst → $bak(中止,不覆寫任何檔案)"
      BACKED=$((BACKED + 1))
    fi
  fi

  if [ "$DRY_RUN" = 1 ]; then
    printf '  %s[dry-run]%s 複製 %s → %s\n' "$C_DIM" "$C_RST" "$src" "$dst"
  else
    mkdir -p "$dstdir" || die "無法建立目錄:$dstdir"
    # -p 保留權限(執行位元)與時間
    cp -p "$src" "$dst" || die "複製失敗:$src → $dst"
  fi
  COPIED=$((COPIED + 1))
}

# 複製整個子目錄。用暫存清單而不是 pipe,因為 pipe 會讓 while 跑在子 shell,
# 計數與 die 都出不來。
install_tree() {
  local srcroot="$SRC_DIR/$1" list f rel
  list="${TMPWORK}/filelist.$$"
  # 排除開發殘留物:__pycache__/*.pyc 是本機 python 版本專屬的位元碼,
  # 裝到別人機器上不會被用到只會誤導(而且會讓「我裝了什麼」變得不可預期);
  # .DS_Store 純粹是 Finder 垃圾;.bak-* 是本安裝器自己的備份,不該被再裝一次。
  find "$srcroot" -type f \
    ! -path '*/__pycache__/*' \
    ! -name '*.pyc' \
    ! -name '*.pyo' \
    ! -name '.DS_Store' \
    ! -name '*.bak-*' \
    -print > "$list" 2>/dev/null || true
  if [ ! -s "$list" ]; then
    rm -f "$list"
    return 1
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel=${f#"$SRC_DIR"/}
    install_file "$f" "$PREFIX/$rel"
  done < "$list"
  rm -f "$list"
  return 0
}

# ---------------------------------------------------------------------------
# 檢查
# ---------------------------------------------------------------------------

check_platform() {
  local os
  os=$(uname -s 2>/dev/null || echo unknown)
  case "$os" in
    Darwin) good "平台:macOS(Darwin)" ;;
    Linux)  good "平台:Linux" ;;
    MINGW* | MSYS* | CYGWIN* | Windows_NT)
      err "偵測到原生 Windows 環境($os)。"
      err "fleet 依賴 tmux,原生 Windows 沒有 tmux。"
      die "請在 WSL2 下安裝與使用:https://learn.microsoft.com/windows/wsl/install"
      ;;
    *)
      die "不支援的平台:$os(只支援 Darwin / Linux)"
      ;;
  esac
}

check_deps() {
  local v major minor missing=0

  # --- tmux ---------------------------------------------------------------
  if ! command -v tmux >/dev/null 2>&1; then
    err "找不到 tmux(必要)。安裝指令:$(pkg_hint tmux)"
    missing=$((missing + 1))
  else
    v=$(tmux -V 2>/dev/null | sed -n 's/^tmux[^0-9]*\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p')
    if [ -z "$v" ]; then
      warn "tmux 版本字串看不懂($(tmux -V 2>&1)),跳過版本檢查(需要 ${REQ_TMUX_MAJOR}.${REQ_TMUX_MINOR} 以上)"
    else
      major=${v% *}
      minor=${v#* }
      if ver_ge "$major" "$minor" "$REQ_TMUX_MAJOR" "$REQ_TMUX_MINOR"; then
        good "tmux $(tmux -V 2>/dev/null | sed 's/^tmux //')"
      else
        err "tmux 版本過舊($major.$minor),需要 ${REQ_TMUX_MAJOR}.${REQ_TMUX_MINOR} 以上。升級:$(pkg_hint tmux)"
        missing=$((missing + 1))
      fi
    fi
  fi

  # --- python3 ------------------------------------------------------------
  if ! command -v python3 >/dev/null 2>&1; then
    err "找不到 python3(必要)。安裝指令:$(pkg_hint python3)"
    missing=$((missing + 1))
  else
    v=$(python3 -c 'import sys; print("%d %d" % sys.version_info[:2])' 2>/dev/null || echo '')
    if [ -z "$v" ]; then
      warn "python3 存在但問不到版本,跳過版本檢查(需要 ${REQ_PY_MAJOR}.${REQ_PY_MINOR} 以上)"
    else
      major=${v% *}
      minor=${v#* }
      if ver_ge "$major" "$minor" "$REQ_PY_MAJOR" "$REQ_PY_MINOR"; then
        good "python3 $major.$minor"
      else
        err "python3 版本過舊($major.$minor),需要 ${REQ_PY_MAJOR}.${REQ_PY_MINOR} 以上。升級:$(pkg_hint python3)"
        missing=$((missing + 1))
      fi
    fi
  fi

  # --- git(選用)---------------------------------------------------------
  if command -v git >/dev/null 2>&1; then
    good "git $(git --version 2>/dev/null | sed 's/^git version //')(選用)"
  else
    warn "沒有 git(選用,只影響 fleet 在 git 工作樹裡的輔助資訊)。安裝:$(pkg_hint git)"
  fi

  if [ "$missing" -gt 0 ]; then
    say ""
    err "有 $missing 項必要相依沒過。"
    die "本安裝器刻意不自動安裝套件(公開工具擅自跑套件管理器太侵入),請照上面的指令自行安裝後重跑。"
  fi
}

check_source() {
  local d
  # bin/fleet 是唯一使用者入口,缺了就不該裝出一個「看起來有裝好」的東西
  if [ ! -f "$SRC_DIR/bin/fleet" ]; then
    err "來源樹缺少 bin/fleet:$SRC_DIR/bin/fleet"
    err "這份 checkout 不完整(或你在錯的目錄跑 install.sh)。"
    die "沒有主程式就沒東西可裝,中止——不會留下半套安裝。"
  fi
  for d in $REQUIRED_DIRS; do
    [ -d "$SRC_DIR/$d" ] || die "來源樹缺少必要目錄:$SRC_DIR/$d"
  done
}

# ---------------------------------------------------------------------------
# config.env 範本(全部註解掉)
# ---------------------------------------------------------------------------

write_config_template() {
  local f=$1 dir
  dir=$(dirname "$f")

  if [ -f "$f" ]; then
    info "設定檔已存在,不動它:$f"
    return 0
  fi

  if [ "$DRY_RUN" = 1 ]; then
    printf '  %s[dry-run]%s 寫入設定檔範本(全部註解掉):%s\n' "$C_DIM" "$C_RST" "$f"
    return 0
  fi

  mkdir -p "$dir" || die "無法建立設定目錄:$dir"
  cat > "$f" <<EOF
# ai-fleet-cli 設定檔
#
# 格式:KEY=value,一行一條,# 開頭是註解。
# 載入規則(見 docs/ARCHITECTURE.md 第 3 節):
#   * 只接受 FLEET_ 開頭的大寫 key
#   * 值不得含反引號或 \$( (拒絕載入)
#   * 優先權:真實環境變數 > 本檔 > 內建預設
#
# 注意:值**不做變數展開**,\$HOME 會被當成字面字串。請寫完整絕對路徑。
#
# 下面全部是註解;要改哪一項就把該行的 # 拿掉。
# 想知道某個值現在是誰決定的,跑:fleet config
#
# ARCHITECTURE.md 第 2 節的變數這裡列了全部,只少兩個、而且是刻意的:
#   FLEET_CONFIG — 就是本檔的路徑,寫在自己裡面沒有意義(用環境變數指定)
#   FLEET_LIBDIR — 由 bin/fleet 從自己的位置推導,手動設只會設錯

# --- 路徑 ------------------------------------------------------------------
# 執行期資料根目錄(registry / state.json / watch.log 都在這底下)
#FLEET_HOME=$DEF_FLEET_HOME

# 艦隊 profile。決定 \$FLEET_HOME/profiles/<name>/,可切多組艦隊
#FLEET_PROFILE=default

# 報告目錄(watcher 盯這裡,有新報告就叫醒指揮官)
#FLEET_REPORTS=$DEF_FLEET_REPORTS

# 派工單目錄(fleet task <id> <brief> 會來這裡找 <brief>.md)
#FLEET_TASKS=$DEF_FLEET_TASKS

# fleet up 的預設工作目錄。不設就是當下的 \$PWD
#FLEET_DEFAULT_DIR=

# --- spawn 用的 tmux ------------------------------------------------------
# fleet up 新開的艦隊跑在這個獨立 socket 上(adopt 來的 worker 不受影響)
#FLEET_SOCKET=agents

# spawn 出來的 session 名
#FLEET_SESSION=fleet

# --- 送訊 ------------------------------------------------------------------
# 貼完字到按 Enter 之間的等待秒數。TUI composer 收字有延遲,
# 太短會按在空框上。網路慢或機器忙可以調大
#FLEET_SEND_DELAY=1

# --- watcher 節奏 ---------------------------------------------------------
# 每輪掃描間隔(秒)
#FLEET_POLL_SECS=3

# 報告檔 mtime 靜置幾秒才算「寫完了」
#FLEET_STABLE_SECS=3

# worker 由 busy 轉閒置超過幾秒,還沒交報告就提醒
#FLEET_IDLE_SECS=90

# stuck 訊號持續幾秒才算真卡住(忙碌中排隊是正常的,不算)
#FLEET_STUCK_SECS=60

# 剛交過報告的 worker,幾秒內不發閒置提醒
#FLEET_QUIET_AFTER_REPORT=300

# 首次啟動時,mtime 超過幾秒的舊報告只建基準線不通知
# (不然一啟動就把整個報告目錄重播一遍洗版)
#FLEET_BACKFILL_SECS=600

# 同一份報告驗不到單號時最多重試幾次,超過就熔斷
#FLEET_MAX_ATTEMPTS=3

# 通知指揮官之前,要不要先對報告跑一次四節 schema 驗證(0 = 關掉)
#FLEET_LINT_REPORTS=1
EOF
  good "已寫入設定檔範本(全部註解掉):$f"
}

# ---------------------------------------------------------------------------
# 安裝
# ---------------------------------------------------------------------------

do_install() {
  local d rc out conflicts n p

  step "環境檢查"
  check_platform
  check_deps
  check_source

  step "安裝位置"
  info "來源:  $SRC_DIR"
  info "PREFIX:$PREFIX"
  info "BINDIR:$BINDIR"

  take_lock "$PREFIX"

  step "複製檔案"
  for d in $REQUIRED_DIRS; do
    install_tree "$d" || die "來源目錄是空的:$SRC_DIR/$d"
  done
  for d in $OPTIONAL_DIRS; do
    if [ -d "$SRC_DIR/$d" ]; then
      install_tree "$d" || warn "$d/ 是空的,跳過"
    else
      warn "來源樹沒有 $d/,跳過(這是選用目錄)"
    fi
  done
  if [ "$DRY_RUN" = 1 ]; then
    info "會複製 $COPIED 個檔案(內容相同而略過 $SKIPPED 個)"
  else
    good "複製 $COPIED 個檔案(內容相同而略過 $SKIPPED 個,備份 $BACKED 個)"
  fi

  step "建立 fleet 指令"
  # 先看 PATH 上有沒有別的 fleet:有的話使用者敲 fleet 可能根本不是這個
  conflicts=$(all_in_path fleet | grep -v "^$BINDIR/fleet$" || true)
  if [ -n "$conflicts" ]; then
    n=$(printf '%s\n' "$conflicts" | wc -l | tr -d ' ')
    warn "PATH 上已經有其他 fleet($n 個),敲 fleet 不一定會叫到這次安裝的版本:"
    printf '%s\n' "$conflicts" | while IFS= read -r p; do
      printf '    %s\n' "$p"
    done
    warn "本次安裝的是:$BINDIR/fleet(不中止,請自行確認 PATH 順序)"
  fi

  run mkdir -p "$BINDIR" || die "無法建立 BINDIR:$BINDIR"
  # -n:BINDIR/fleet 若已是指向某目錄的 symlink,沒有 -n 會裝到那個目錄裡面去
  run ln -sfn "$PREFIX/bin/fleet" "$BINDIR/fleet" || die "無法建立 symlink:$BINDIR/fleet"
  did "symlink:$BINDIR/fleet → $PREFIX/bin/fleet"

  step "建立執行期目錄"
  run mkdir -p "$DEF_FLEET_HOME/profiles/default" || die "無法建立 $DEF_FLEET_HOME/profiles/default"
  run mkdir -p "$DEF_FLEET_REPORTS" || die "無法建立 $DEF_FLEET_REPORTS"
  run mkdir -p "$DEF_FLEET_TASKS" || die "無法建立 $DEF_FLEET_TASKS"
  did "$DEF_FLEET_HOME/profiles/default"
  did "$DEF_FLEET_REPORTS"
  did "$DEF_FLEET_TASKS"

  step "設定檔"
  write_config_template "$CONFIG_FILE"

  step "驗證安裝"
  if [ "$DRY_RUN" = 1 ]; then
    say "  ${C_DIM}[dry-run]${C_RST} 執行 $BINDIR/fleet version 並檢查離開碼"
  else
    # 只看 x bit 是不夠的:語法錯誤的腳本一樣有 x bit。要看實跑的離開碼。
    rc=0
    out=$("$BINDIR/fleet" version 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
      err "執行 $BINDIR/fleet version 失敗(離開碼 $rc):"
      printf '%s\n' "$out" | sed 's/^/    /' >&2
      die "安裝出來的 fleet 跑不起來,請回報這段輸出。"
    fi
    good "fleet version → $out"
  fi

  print_post_install
}

print_post_install() {
  local need_path=0

  step "接下來"

  if ! in_path "$BINDIR"; then
    need_path=1
  fi

  if [ "$need_path" = 1 ]; then
    say "${C_YLW}1) $BINDIR 不在你的 PATH 上${C_RST},把這行加進你的 shell rc:"
    say ""
    say "     export PATH=$(pretty_path "$BINDIR"):\$PATH"
    say ""
    say "   ${C_DIM}Debian/Ubuntu 的 ~/.bashrc 前段有「非互動就 return」的 early return,"
    say "   加在檔尾對非互動 shell 無效 → 請加在**檔案最前面**。${C_RST}"
    say "   ${C_DIM}(本安裝器不會替你改 rc,理由見 install.sh 檔頭。)${C_RST}"
  else
    say "1) PATH 已包含 $BINDIR,直接敲 fleet 就行。"
  fi

  say ""
  say "2) 補全(選用,一樣自己貼進 rc):"
  if [ -f "$SRC_DIR/completion/fleet.zsh" ]; then
    say "     ${C_DIM}# zsh — 放在 compinit 之後${C_RST}"
    say "     source $(pretty_path "$PREFIX/completion/fleet.zsh")"
  fi
  if [ -f "$SRC_DIR/completion/fleet.bash" ]; then
    say "     ${C_DIM}# bash${C_RST}"
    say "     source $(pretty_path "$PREFIX/completion/fleet.bash")"
  fi

  say ""
  say "3) 跑健檢:"
  say ""
  say "     ${C_GRN}fleet doctor${C_RST}"
  say ""
  say "   ${C_DIM}它會逐項告訴你還缺什麼,每個問題都附可直接複製的修法。${C_RST}"

  if [ -d "$OLD_ROOT" ] && [ -f "$OLD_ROOT/registry" ]; then
    say ""
    say "${C_YLW}4) 偵測到舊版個人佈局:$OLD_ROOT${C_RST}"
    say "   要搬過來的話:"
    say ""
    say "     $(shq "$SRC_DIR/install.sh") --migrate --dry-run   ${C_DIM}# 先看會做什麼${C_RST}"
    say "     $(shq "$SRC_DIR/install.sh") --migrate"
  fi
  say ""
}

# ---------------------------------------------------------------------------
# 解除安裝
# ---------------------------------------------------------------------------
# 只移除程式本體。使用者資料($FLEET_HOME / 報告 / 派工單 / config.env)
# 一律保留——解除安裝一個工具不該順手刪掉使用者累積的東西。
# 印出路徑讓他自己決定。

do_uninstall() {
  local target

  step "解除安裝"
  info "PREFIX:$PREFIX"
  info "BINDIR:$BINDIR"

  if [ -e "$BINDIR/fleet" ] || [ -L "$BINDIR/fleet" ]; then
    target=""
    if [ -L "$BINDIR/fleet" ]; then
      target=$(readlink "$BINDIR/fleet" 2>/dev/null || true)
    fi
    case "$target" in
      "$PREFIX"/*)
        run rm -f "$BINDIR/fleet" || die "無法移除 $BINDIR/fleet"
        good "已移除 symlink:$BINDIR/fleet"
        ;;
      '')
        warn "$BINDIR/fleet 不是 symlink(可能是別人裝的),不動它"
        ;;
      *)
        warn "$BINDIR/fleet 指向 $target,不是這次要移除的 $PREFIX,不動它"
        ;;
    esac
  else
    info "$BINDIR/fleet 不存在,跳過"
  fi

  if [ -d "$PREFIX" ]; then
    take_lock "$PREFIX"
    run rm -rf -- "${PREFIX:?}" || die "無法移除 $PREFIX"
    # PREFIX 整個沒了,鎖也跟著沒了,不要再讓 trap 去 rmdir
    LOCK_DIR=""
    good "已移除 $PREFIX"
  else
    info "$PREFIX 不存在,跳過"
  fi

  step "以下是你的資料,刻意保留"
  say "  執行期資料:$DEF_FLEET_HOME"
  say "  報告目錄:  $DEF_FLEET_REPORTS"
  say "  派工單目錄:$DEF_FLEET_TASKS"
  say "  設定檔:    $CONFIG_FILE"
  say ""
  say "  ${C_DIM}確定不要了再自己刪:${C_RST}"
  # config.env 若本來就在 FLEET_HOME 底下,再列一次只是噪音
  case "$CONFIG_FILE" in
    "$DEF_FLEET_HOME"/*) say "    rm -rf $(shq "$DEF_FLEET_HOME")" ;;
    *) say "    rm -rf $(shq "$DEF_FLEET_HOME") $(shq "$CONFIG_FILE")" ;;
  esac
  say "  ${C_DIM}(報告與派工單多半是你自己寫的東西,這裡刻意不列進上面那行。)${C_RST}"
  say ""
}

# ---------------------------------------------------------------------------
# 從舊版個人佈局遷移
# ---------------------------------------------------------------------------
# 舊佈局($OLD_ROOT,預設 ~/.claude/fleet):
#   registry    id<TAB>socket<TAB>pane<TAB>kind
#               ——但 spawn 出來的列,pane 欄可能是 `fleet:cc1` 這種
#                 session:window 名稱而不是 %NN
#   commander   單行,只有 pane(如 %15)
#   .state/     一堆 rep-*.notified / rep-*.hash / w-*.wasbusy 散檔
#
# 原則:**舊檔一律不刪,只複製**。遷移是可以重跑的,砍掉就回不去了。

migrate_registry() {
  local src=$1 dst=$2 tmp bad ok_n=0 bad_n=0 line id sock pane kind

  if [ ! -f "$src" ]; then
    info "沒有舊 registry($src),跳過"
    return 0
  fi

  tmp="${TMPWORK}/registry.new"
  bad="${TMPWORK}/registry.bad"
  : > "$tmp"
  : > "$bad"

  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    case "$line" in '#'*) continue ;; esac
    id=$(printf '%s' "$line" | cut -f1)
    sock=$(printf '%s' "$line" | cut -f2)
    pane=$(printf '%s' "$line" | cut -f3)
    kind=$(printf '%s' "$line" | cut -f4)
    [ -n "$id" ] || continue
    [ -n "$sock" ] || sock='-'

    # 新版只接受穩定 pane id(%NN)。session:win.pane 座標會因為別人
    # 插一格而整排位移,派工就送錯人——這正是舊版踩過的坑,不能搬進來。
    if printf '%s' "$pane" | grep -qE '^%[0-9]+$'; then
      printf '%s\t%s\t%s\t%s\n' "$id" "$sock" "$pane" "$kind" >> "$tmp"
      ok_n=$((ok_n + 1))
    else
      printf '%s\t%s\t%s\t%s\n' "$id" "$sock" "$pane" "$kind" >> "$bad"
      bad_n=$((bad_n + 1))
    fi
  done < "$src"

  info "舊 registry:$ok_n 筆可直接搬,$bad_n 筆需要重新登記"

  if [ "$bad_n" -gt 0 ]; then
    say ""
    warn "以下 $bad_n 筆的 pane 欄不是穩定 pane id(%NN),**不會搬過去**:"
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | cut -f1)
      pane=$(printf '%s' "$line" | cut -f3)
      printf '    %-12s pane=%s\n' "$id" "$pane"
    done < "$bad"
    say ""
    say "  ${C_DIM}原因:session:window 座標會因為別人插一格而整排位移,派工會送錯人。"
    say "  新版只接受 tmux 的穩定 pane id(%NN)。${C_RST}"
    say "  這幾隻請重新登記(pane 還活著的話):"
    say ""
    say "     fleet discover              ${C_DIM}# 掃出現有 pane 與它們真正的 %NN${C_RST}"
    say "     fleet adopt <id> <%NN> [socket]"
    say ""
  fi

  if [ "$ok_n" -eq 0 ]; then
    rm -f "$tmp" "$bad"
    return 0
  fi

  if [ "$DRY_RUN" = 1 ]; then
    printf '  %s[dry-run]%s 寫入 %s(%s 筆)\n' "$C_DIM" "$C_RST" "$dst" "$ok_n"
    say "  ${C_DIM}內容預覽:${C_RST}"
    sed 's/^/      /' "$tmp"
  else
    mkdir -p "$(dirname "$dst")" || die "無法建立 $(dirname "$dst")"
    install_file "$tmp" "$dst"
    good "registry → $dst($ok_n 筆)"
  fi

  rm -f "$tmp" "$bad"
  return 0
}

migrate_commander() {
  local src=$1 dst=$2 line nf sock pane tmp

  if [ ! -f "$src" ]; then
    info "沒有舊 commander($src),跳過"
    return 0
  fi

  line=$(head -n 1 "$src" 2>/dev/null || true)
  if [ -z "$line" ]; then
    warn "舊 commander 是空的,跳過"
    return 0
  fi

  nf=$(printf '%s' "$line" | awk -F'\t' '{print NF}')
  if [ "$nf" -ge 2 ]; then
    sock=$(printf '%s' "$line" | cut -f1)
    pane=$(printf '%s' "$line" | cut -f2)
  else
    # 舊版只有一欄(pane),一律視為預設 socket
    sock='-'
    pane=$(printf '%s' "$line" | cut -f1)
  fi

  if ! printf '%s' "$pane" | grep -qE '^%[0-9]+$'; then
    warn "舊 commander 的 pane「${pane}」不是 %NN,不搬。"
    say "  在你(指揮官)那一格跑這兩行重設:"
    say ""
    say "     tmux display -p '#{pane_id}'"
    say "     fleet commander <上面印出來的 %NN>"
    say ""
    return 0
  fi

  tmp="${TMPWORK}/commander.new"
  printf '%s\t%s\n' "$sock" "$pane" > "$tmp"

  if [ "$DRY_RUN" = 1 ]; then
    printf '  %s[dry-run]%s 寫入 %s:socket=%s TAB pane=%s(舊的單欄格式 → 新的兩欄格式)\n' \
      "$C_DIM" "$C_RST" "$dst" "$sock" "$pane"
  else
    mkdir -p "$(dirname "$dst")" || die "無法建立 $(dirname "$dst")"
    install_file "$tmp" "$dst"
    good "commander → $dst($sock<TAB>$pane)"
  fi
  rm -f "$tmp"
  return 0
}

do_migrate() {
  local prof_dir n

  step "從舊版佈局遷移"
  info "來源:$OLD_ROOT"
  prof_dir="$DEF_FLEET_HOME/profiles/default"
  info "目標:$prof_dir"

  if [ ! -d "$OLD_ROOT" ]; then
    die "找不到舊佈局目錄:$OLD_ROOT(要換位置的話設環境變數 FLEET_OLD_DIR)"
  fi

  if [ "$DRY_RUN" != 1 ]; then
    mkdir -p "$prof_dir" || die "無法建立 $prof_dir"
  fi

  step "registry"
  migrate_registry "$OLD_ROOT/registry" "$prof_dir/registry"

  step "commander"
  migrate_commander "$OLD_ROOT/commander" "$prof_dir/commander"

  step ".state/ 散檔"
  if [ -d "$OLD_ROOT/.state" ]; then
    n=$(find "$OLD_ROOT/.state" -type f 2>/dev/null | wc -l | tr -d ' ')
    info "舊狀態散檔 $n 個,**刻意不遷移**。"
    say "  ${C_DIM}兩個理由:"
    say "  1. 格式已改——新版全部收進單一 state.json,沒有 .notified / .hash 散檔。"
    say "  2. 舊 key 用 tr -c 'A-Za-z0-9_.-' '_' 逐 byte 轉碼,中文主題會被壓成一串底線,"
    say "     同日同 worker 的兩份中文報告會撞 key、後者永久靜音。搬進來等於把 bug 一起搬。${C_RST}"
    say ""
    say "  ${C_GRN}不會因此洗版:${C_RST}第一次啟動 watcher 時,state.json 是空的,"
    say "  但 backfill 保護會把「首次見到且 mtime 超過 FLEET_BACKFILL_SECS(預設 600 秒)"
    say "  的舊報告」只建基準線、不發通知。也就是舊報告不會重播一遍。"
    say "  ${C_DIM}想連剛剛那幾份新報告也一起靜音,把 FLEET_BACKFILL_SECS 調小再啟動一次即可。${C_RST}"
  else
    info "沒有 $OLD_ROOT/.state,跳過"
  fi

  step "完成"
  say "舊檔一個都沒動(遷移只複製不刪)。確認新版跑起來之後,這些可以自己清:"
  say ""
  say "  $OLD_ROOT/registry"
  say "  $OLD_ROOT/commander"
  say "  $OLD_ROOT/.state/"
  say ""
  say "  ${C_DIM}建議先留著跑幾天,確定沒問題再刪。${C_RST}"
  say ""
  if [ "$DRY_RUN" = 1 ]; then
    info "以上是 --dry-run,什麼都沒真的寫入。"
  else
    say "接著跑健檢:${C_GRN}fleet doctor${C_RST}"
  fi
  say ""
}

# ---------------------------------------------------------------------------
# 參數
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
用法:./install.sh [選項]

安裝 ai-fleet-cli。**不會修改你的 shell rc**——需要設定的東西一律印出來讓你自己貼。

選項:
  --prefix DIR    程式安裝位置(預設 \${XDG_DATA_HOME:-\$HOME/.local/share}/fleet-cli)
  --bindir DIR    fleet 指令的 symlink 位置(預設 \$HOME/.local/bin)
  --uninstall     移除程式本體與 symlink;**保留** \$FLEET_HOME 與 config.env
  --migrate       從舊版個人佈局(${OLD_ROOT})搬 registry / commander 過來,舊檔不刪
  --dry-run       印出所有會做的動作,但什麼都不做(可搭配上面任一模式)
  -h, --help      這份說明

環境變數:
  FLEET_HOME      執行期資料根目錄(預設 \${XDG_DATA_HOME:-\$HOME/.local/share}/fleet)
  FLEET_REPORTS   報告目錄(預設 \$HOME/fleet/reports)
  FLEET_TASKS     派工單目錄(預設 \$HOME/fleet/tasks)
  FLEET_CONFIG    設定檔路徑(預設 \${XDG_CONFIG_HOME:-\$HOME/.config}/fleet/config.env)
  FLEET_OLD_DIR   --migrate 的來源(預設 \$HOME/.claude/fleet)

例:
  ./install.sh
  ./install.sh --prefix /opt/fleet-cli --bindir /usr/local/bin
  ./install.sh --migrate --dry-run
  ./install.sh --uninstall
EOF
}

PREFIX="${XDG_DATA_HOME:-$HOME/.local/share}/fleet-cli"
BINDIR="$HOME/.local/bin"
OLD_ROOT="${FLEET_OLD_DIR:-$HOME/.claude/fleet}"

DEF_FLEET_HOME="${FLEET_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/fleet}"
DEF_FLEET_REPORTS="${FLEET_REPORTS:-$HOME/fleet/reports}"
DEF_FLEET_TASKS="${FLEET_TASKS:-$HOME/fleet/tasks}"
CONFIG_FILE="${FLEET_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/fleet/config.env}"

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)
      [ $# -ge 2 ] || die "--prefix 後面要接目錄"
      PREFIX=$2; shift 2 ;;
    --prefix=*)
      PREFIX=${1#--prefix=}; shift ;;
    --bindir)
      [ $# -ge 2 ] || die "--bindir 後面要接目錄"
      BINDIR=$2; shift 2 ;;
    --bindir=*)
      BINDIR=${1#--bindir=}; shift ;;
    --uninstall) MODE=uninstall; shift ;;
    --migrate)   MODE=migrate; shift ;;
    --dry-run)   DRY_RUN=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) err "不認得的參數:$1"; say ""; usage; exit 2 ;;
  esac
done

case "$PREFIX" in /*) ;; *) PREFIX="$PWD/$PREFIX" ;; esac
case "$BINDIR" in /*) ;; *) BINDIR="$PWD/$BINDIR" ;; esac

SRC_DIR=$(self_dir "$0") || die "無法定位 install.sh 自己的位置"

# 暫存工作區(檔案清單、遷移中間檔)。放系統 tmp,離開時清掉。
TMPWORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-install.XXXXXX") || die "無法建立暫存目錄"
_cleanup_tmp() { [ -n "${TMPWORK:-}" ] && rm -rf "$TMPWORK" 2>/dev/null || true; }
trap 'cleanup; _cleanup_tmp' EXIT
trap 'cleanup; _cleanup_tmp; exit 130' INT
trap 'cleanup; _cleanup_tmp; exit 143' TERM

say ""
info "ai-fleet-cli 安裝器"
if [ "$DRY_RUN" = 1 ]; then
  warn "--dry-run:以下只會印出動作,不會真的做任何事"
fi

case "$MODE" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
  migrate)   do_migrate ;;
esac
