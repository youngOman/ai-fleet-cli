# ai-fleet-cli 架構契約

> 這份是**實作契約**：所有子系統（CLI、watcher、mon、install、測試、補全）都以這份為準。
> 改動這份等於改動介面，要同步改所有引用處。

## 0. 設計前提

| 前提 | 理由 |
|---|---|
| 目標 shell 是 **bash 3.2**（macOS 內建） | 不能用關聯陣列、`${var,,}`、`declare -A`、`mapfile`、`&<<<` 以外的 bash4 語法 |
| 純函式邏輯放 **python3**，tmux I/O 留在 **bash** | 邏輯要可測；tmux 互動不可測，只能靠 fixture |
| **adopt 既有 pane 是主要模式**，不是自己開站 | 不能假設能控制 pane 生命週期；送訊一律要回讀驗證 |
| 訊號比對規則是**資料不是程式碼** | 同一份 regex 曾被複製到 4 個檔案並漂移過 |

## 1. 目錄佈局

```
ai-fleet-cli/
  bin/fleet                主 CLI（唯一使用者入口）
  lib/core.sh              路徑解析 / 設定載入 / 顏色 / log
  lib/registry.sh          registry 讀寫（含檔案鎖）
  lib/signals.sh           讀 adapters/*.conf，提供 pane_busy / pane_stuck / ...
  lib/tmuxio.sh            wtmux / tui_ready / composer_busy / send_verified
  adapters/cc.conf         claude adapter（純資料）
  adapters/cx.conf         codex adapter（純資料）
  libexec/fleet-watcher    回報閉環守護行程（bash）
  libexec/fleet-mon        即時看板（python3）
  libexec/fleet-state      狀態機 / 去重 / 熔斷（python3，唯一寫 state.json 的人）
  libexec/fleet-lint       報告四節 schema 驗證（python3）
  share/task-template.md   派工單模板
  share/report-template.md 報告模板
  completion/fleet.zsh     zsh 補全（動態從 registry 抓 id）
  completion/fleet.bash    bash 補全
  install.sh               安裝器
  scripts/scan.py          release gate：擋個人絕對路徑 / 憑證
  scripts/check-version.sh 版本一致性檢查
  tests/                   測試
  docs/                    文件
```

## 2. 執行期路徑（可被環境變數覆寫）

| 變數 | 預設 | 用途 |
|---|---|---|
| `FLEET_HOME` | `${XDG_DATA_HOME:-$HOME/.local/share}/fleet` | 執行期資料根目錄 |
| `FLEET_CONFIG` | `${XDG_CONFIG_HOME:-$HOME/.config}/fleet/config.env` | 設定檔 |
| `FLEET_PROFILE` | `default` | 艦隊 profile（支援多艦隊；決定 `$FLEET_HOME/profiles/<p>/`） |
| `FLEET_REPORTS` | `$HOME/fleet/reports` | 報告目錄 |
| `FLEET_TASKS` | `$HOME/fleet/tasks` | 派工單目錄 |
| `FLEET_DEFAULT_DIR` | `$PWD` | `fleet up` 的預設工作目錄 |
| `FLEET_SOCKET` | `agents` | spawn 用的 tmux socket |
| `FLEET_SESSION` | `fleet` | spawn 用的 tmux session |
| `FLEET_LIBDIR` | 由 `bin/fleet` 自動推導 | 安裝後的 lib/libexec/adapters 根目錄 |
| `FLEET_SEND_DELAY` | `1` | 貼字與 Enter 之間的等待秒數 |
| `FLEET_POLL_SECS` | `3` | watcher 掃描間隔 |
| `FLEET_STABLE_SECS` | `3` | 報告檔靜置多久才算落地 |
| `FLEET_IDLE_SECS` | `90` | 由忙轉閒多久算「閒置未交報告」 |
| `FLEET_STUCK_SECS` | `60` | 卡住訊號持續多久算真卡住 |
| `FLEET_QUIET_AFTER_REPORT` | `300` | 剛交過報告後多久內不發閒置警報 |
| `FLEET_BACKFILL_SECS` | `600` | 首次見到且超過這個秒數的舊報告只建基準線不通知 |
| `FLEET_MAX_ATTEMPTS` | `3` | 送達驗證連續失敗幾次後熔斷 |
| `FLEET_REPORT_COOLDOWN_SECS` | `300` | 同一份報告通知後多久內的補寫合併成一則（`0` 關閉） |
| `FLEET_LINT_REPORTS` | `1` | 通知前是否對報告跑四節驗證（`0` 關閉） |
| `FLEET_MAIN_PANE_WIDTH` | `60%` | 版面左側主 pane 的寬度 |
| `FLEET_MIN_PANE_HEIGHT` | `10` | 每格最低高度；再切下去會低於此值就改開獨立 window |

**以上全部**都可以在 `config.env` 覆寫，也可以用真實環境變數覆寫（環境變數優先）。

Profile 目錄內容（`$FLEET_HOME/profiles/$FLEET_PROFILE/`）：

```
registry        id<TAB>socket<TAB>pane<TAB>kind
commander       socket<TAB>pane      ← 注意：兩欄，支援指揮官不在預設 socket
state.json      單一狀態檔（去重 / 熔斷 / worker 轉換）
watch.log       結構化日誌（JSON Lines）
watch.pid       daemon pid
locks/          mkdir 原子鎖
```

**沒有任何 `.notified` / `.hash` 散檔。** 全部進 `state.json`。

## 3. 設定檔格式

`config.env` 是 **`KEY=value` 一行一條**，`#` 開頭是註解。刻意不用 TOML——
bash 沒有可靠的 TOML parser，自己寫一個是 bug 工廠。載入時只接受
`^[A-Z_][A-Z0-9_]*=` 且值不含反引號/`$(`，不符合的行拒絕載入並警告。

值的處理只有三件事，其餘一律當字面字串：

1. 去掉**包住整個值**的成對單／雙引號
2. 展開**開頭**的 `~/` 與 `$HOME/`（也接受單獨的 `~` 與 `$HOME`）
3. 其他位置的 `$VAR` 不展開 —— 做一般變數展開等於把設定檔變回可執行程式碼，
   上面擋掉 `$( )` 與反引號就白做了。要別的路徑請寫完整絕對路徑。

環境變數優先權：**真實環境變數 > config.env > 內建預設**。

## 4. adapter 檔格式（`adapters/<kind>.conf`）

純 `key=value`，值是 ERE（給 `grep -E` 與 python `re` 共用，所以只能用兩者交集語法）。

```
name=claude
command=claude
detect=bypass permissions|Claude Code|for shortcuts|esc to interrupt
ready=for shortcuts|bypass permissions on
busy=esc to interrupt|without interrupting|shell still running|Running [0-9]+ shell
stuck=Press up to edit queued messages|\[Pasted Content [0-9]+ chars\]
asking=Do you want|❯ 1\.|Ready to submit
ctx=◔ *([0-9]+)%
trust=trust this folder|Do you trust
composer=❯[[:space:]]+[^[:space:]]
```

`composer` 是「使用者正在打字」的偵測規則:composer 行後面有非空白字元就代表
他打到一半,這時**絕對不能注入通知**。沒定義時退回泛用規則 `❯[[:space:]]+[^[:space:]]`。
`ctx` 留空（如 `adapters/cx.conf`）代表這種 CLI 沒有 context 百分比，看板顯示 `-`。

選用的 `composer_ignore` 是**輸入框灰字提示的白名單**：空輸入框裡的提示文字
（codex 會顯示 `Summarize recent commits` 這類）會讓 `composer` 誤判成「使用者在打字」，
於是通知永遠送不出去。composer 行全部命中 `composer_ignore` 就視為輸入框是空的。

另有選用的**自動應答**欄位（`N` 為 1–9，可定義多組）：

```
autoreply1_match=Retry with a faster model
autoreply1_keys=2
```

watcher 巡邏時若在畫面上比對到 `autoreplyN_match`，就送出 `autoreplyN_keys` 再送 Enter。
用途是讓無人看管的 worker 不被互動攔截框卡死（例如「要不要降級到快模型」一律選「不要」）。
命中自動應答的那一輪**跳過狀態判定**——畫面正要變，這時判忙碌／閒置沒有意義。

新增一種 worker CLI＝新增一個 `.conf`，**不需要改任何程式碼**。
`lib/signals.sh` 與 `libexec/fleet-mon`、`libexec/fleet-state` 都從這裡讀，
regex 只有這一份，不再複製。

## 5. `state.json` schema

```json
{
  "version": 1,
  "reports": {
    "<報告檔名原文（含 UTF-8，不做任何轉碼）>": {
      "mtime": 1754150400,
      "hash": "md5hex",
      "attempts": 0,
      "notified_at": 1754150403
    }
  },
  "workers": {
    "<worker id>": {
      "wasbusy": 1754150000,
      "lastreport": 1754150400,
      "stuck_since": 0,
      "stuck_notified": false,
      "idle_notified": false
    }
  }
}
```

**key 直接用檔名原文** —— 舊版用 `tr -c 'A-Za-z0-9_.-' '_'` 逐 byte 轉碼，
中文主題會被壓成一串 `_`，兩份同日同 worker 的中文報告會撞 key、後者永久靜音。
JSON key 本來就吃 UTF-8，這個 bug 直接消失。

## 6. `libexec/fleet-state` CLI 契約

所有子命令都讀寫 `$1` 指定的 state.json（原子寫：temp + rename）。

| 子命令 | 輸入 | 輸出（stdout） |
|---|---|---|
| `plan-reports --state F --dir D [--dir D2] --now N --stable S --backfill B --max-attempts M --ids "a b c"` | — | 每行一筆待通知：`path<TAB>tag<TAB>worker<TAB>topic`；同時就地寫入 backfill 基準線 |
| `record-report --state F --path P --result ok\|fail\|skip --now N` | — | — |
| `worker-tick --state F --id I --busy 0\|1 --stuck 0\|1 --now N --idle-secs X --stuck-secs Y --quiet-after Z` | — | `notify-stuck` / `notify-idle` / 空 |
| `record-worker --state F --id I --event stuck-notified\|idle-notified\|report --now N` | — | — |
| `gc --state F --dir D [--dir D2] --ids "a b c"` | — | 移除已不存在的報告 entry 與不在 `--ids` 裡的 worker entry |
| `dump --state F` | — | pretty JSON（給 doctor / 測試用） |

`--ids` 是 registry 裡的真實 worker id 清單。報告檔名解析 worker 時
**只接受能對上 registry 的 id（取最長匹配）**，對不上就填 `-`，
不再用 `cut -d- -f3` 猜出幽靈 worker。

## 7. 送訊協定（`lib/tmuxio.sh`，一條都不能少）

```
send_verified <socket> <pane> <訊息> <短單號>
  1. pane_in_mode → send-keys -X cancel        （copy-mode 會整包吃掉輸入）
  2. tui_ready 失敗 → return 3（不送、不記帳）  （前景是 shell）
  3. composer_busy → return 2（不送、不記帳）   （使用者正在打字，插隊會洗掉他的句子）
  4. send-keys -l -- "$msg"
  5. sleep $FLEET_SEND_DELAY（預設 1）          （TUI composer 收字有延遲）
  6. send-keys Enter
  7. sleep 1；capture-pane -S -150 | grep -qF "$tag"
     → 0 成功 / 1 驗不到                        （只 grep 短單號，長句必被折行）
```

回傳碼語意：`0` 送達 / `1` 驗不到（要記 attempt） / `2` 使用者在打字（不記帳） / `3` TUI 沒起來（不記帳）。

**`wtmux` 一律帶 socket**，包含通知指揮官那條路徑——舊版通知用裸 `tmux`，
指揮官若不在預設 socket 就全部靜默失敗。

## 8. 三種主動通知

| 訊號 | 觸發條件 |
|---|---|
| 📥 交報告 | 報告目錄出現新檔或內容 hash 變更，且 mtime 靜置 `STABLE_SECS`（3）秒 |
| ⚠️ 閒置未交報告 | worker 由 busy 轉非 busy 超過 `IDLE_SECS`（90）秒，且距最後一份報告 > `QUIET_AFTER_REPORT`（300）秒 |
| 🚧 卡住 | `stuck` 訊號出現超過 `STUCK_SECS`（60）秒 **且非 busy**（忙碌中排隊是正常的） |

首次啟動的 backfill 保護：首次見到且 mtime 超過 `BACKFILL_SECS`（600）秒的舊檔
只建基準線不通知，避免一次洗版整個報告目錄。

## 9. 明確不做

- ❌ 不改成「worker 主動回報」——已證明會失敗，盯報告檔落地是核心決策
- ❌ 不重寫成其他語言
- ❌ 不自動修改使用者的 shell rc（install.sh 只印可複製的指令）
- ❌ 不加自動合併 PR
- ❌ 不注入 `~/.claude/settings.json`
