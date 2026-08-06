# ai-fleet-cli

**一個指揮官 AI，用 tmux 指揮多個 worker AI 平行開發，而且 worker 做完會自動把你叫醒。**

多開幾個 AI 終端很容易，難的是**指揮官不知道誰做完了**。
worker 做完不會敲你，你就只能一直輪詢「好了沒」，或是掛機空等——
實測發生過 worker 完工 14 分鐘沒人收、完成 21 分鐘後才被發現「怎麼還沒開始」。

`fleet` 解決的就是這件事：worker 完工把報告寫進共用目錄，
背景 watcher 偵測到報告檔落地，就**自動把一句短訊注入指揮官的輸入框**把人叫醒。

這套工具的價值不在「開很多 AI」，在**回報閉環**與**假訊號防護**。

---

## 60 秒示範

```bash
# 1. 開一組新艦隊（預設 2 claude + 1 codex），開完直接把你帶進畫面
fleet up

# 2. 告訴 fleet 你（指揮官）坐在哪 —— 在你自己那格終端裡跑
fleet commander here

# 3. 派工：寫好 brief，送短訊指向它
fleet task cc1 refactor-auth      # 自動找 $FLEET_TASKS/refactor-auth.md

# 4. 看板（不帶參數就是看板）
fleet
#   id    kind    狀態     ctx    最後活動
#   cc1   claude  🏃 跑中   68%    Editing src/auth.rs
#   cx1   codex   😴 閒置   91%    -

# 5. 然後你就可以去做別的事。
#    cc1 寫完報告的那一刻，你的輸入框會自己跳出：
#    📥 cc1 交報告：20260803-1420-cc1-refactor-auth.md (r1754209200)
```

已經自己開好一堆 claude / codex 了？不用重開，一行接管全部：

```bash
fleet discover --adopt        # 掃到的全部接管、自動取名（會跳過你自己那格）
```

---

## 快速指令

日常九成只會用到這幾行：

| 想幹嘛 | 指令 |
|---|---|
| 開一組新艦隊 | `fleet up` |
| 一組裡再加一隻 | `fleet add cc` ／ `fleet add cx` ／ `fleet add cc -n 3` |
| 看板 | `fleet` |
| 跟某一隻講話 | `fleet send <名字> "文字"` |
| 派正式任務 | `fleet task <名字> <brief>` |
| 看某一隻的畫面 | `fleet peek <名字>` |
| 進去艦隊畫面 | `fleet attach` |
| 收掉一組 | `fleet down <組名>` |
| 出問題時 | `fleet doctor` |

第一次用多一步 `fleet commander here`（在你自己坐的那格終端裡跑），
之後 worker 交報告就會自動叫醒你。

**你不需要記 `%NN`。** 那是 tmux 給每格終端的內部編號，
`fleet commander here` 會自己抓、`fleet discover` 會把指令整行印好給你複製。

多開幾組互不影響 —— 再打一次 `fleet up` 就是全新的一組，
`fleet ls` 的 `socket` 欄會顯示它屬於哪一組（`agents`、`agents-2`…）。

---

## 安裝

```bash
git clone https://github.com/<you>/ai-fleet-cli.git
cd ai-fleet-cli
./install.sh
```

`install.sh` 會：

- 檢查 tmux / python3 版本
- 建立執行期目錄（`FLEET_HOME`、報告目錄、派工單目錄）
- 把 `fleet` 裝到你的 PATH
- 偵測到 `~/.claude/skills/` 就順便裝[指揮官 skill](#指揮官-skillclaude-code)（`--no-skill` 可關）

**它不會改你的 shell rc。**
需要設環境變數時，它只會把該加的 `export` 指令印出來讓你自己複製貼上——
自動改別人的 `.zshrc` / `.bashrc` 是很糟糕的行為。

裝完先跑健檢：

```bash
fleet doctor
```

---

## 核心概念

### 兩種 worker 來源

| 來源 | 怎麼來 | socket | `fleet down` 時 |
|---|---|---|---|
| **adopt** | 接管你**已經開好**的 pane（在你日常的 tmux session 裡） | `-`（預設 socket） | **只解除登記，永不 kill** |
| **spawn** | `fleet up` 新開一組，跑在獨立 socket（`FLEET_SOCKET`，預設 `agents`） | `agents` | kill 掉 |

**adopt 是主要模式。** 使用者通常已經開好一堆 AI 終端了，重開一次（啟動＋信任提示＋載入專案）很慢，
而且 fleet 不該假設自己能控制 pane 的生命週期。

兩種來源用同一組 id 定址、同一套 `send` / `peek` / `wait`，registry 會記住各自的 socket。

### 回報閉環：三種主動通知

watcher 是背景常駐行程，週期性掃報告目錄與各 worker 的畫面，符合條件就注入短訊給指揮官。

| 訊號 | 觸發條件 |
|---|---|
| 📥 交報告 | 報告目錄出現新檔或內容 hash 變更，且 mtime 靜置 `STABLE_SECS`（3）秒 |
| ⚠️ 閒置未交報告 | worker 由 busy 轉非 busy 超過 `IDLE_SECS`（90）秒，且距最後一份報告 > `QUIET_AFTER_REPORT`（300）秒 |
| 🚧 卡住 | `stuck` 訊號出現超過 `STUCK_SECS`（60）秒**且非 busy**（忙碌中排隊是正常的，不算卡住） |

首次啟動有 backfill 保護：首次見到且 mtime 超過 `BACKFILL_SECS`（600）秒的舊檔只建基準線不通知，
避免一啟動就把整個報告目錄重播一遍洗版。

### 自動應答：不讓攔截框卡死無人看管的 worker

watcher 巡邏時如果在 worker 畫面上比對到 adapter 定義的攔截框，
會**自動送出預設按鍵再送 Enter**，讓 worker 不會因為一個沒人回答的對話框而停擺整晚。
內建範例：codex 的「Retry with a faster model」一律選 `2`（等強模型，不降級品質）。

規則寫在 adapter 檔裡（`autoreplyN_match` / `autoreplyN_keys`，`N` 為 1–9），是資料不是程式碼——
你的 CLI 有別的攔截框，加兩行 conf 就好。命中自動應答的那一輪會**跳過狀態判定**，
因為畫面正要變，這時判忙碌／閒置沒有意義。

> **為什麼是盯報告檔，而不是要求 worker 主動回報？**
> 因為 worker 會忘記回報，codex 還會卡在輸入框。詳見 [docs/design.md](docs/design.md)。

---

## 指令

### 看板與健檢

| 指令 | 做什麼 |
|---|---|
| `fleet` | 即時看板（不帶參數的預設動作） |
| `fleet mon [-w]` | 看板；`-w` 持續刷新（**需要真 TTY**，被 pipe 時只印一張快照） |
| `fleet -w` | `fleet mon -w` 的 alias |
| `fleet doctor` | 健檢：tmux / python3 / PATH / watcher / 報告目錄 / 指揮官設定 / 舊佈局 |
| `fleet version` | 版本 |

### 編制管理

| 指令 | 做什麼 |
|---|---|
| `fleet discover` | 掃現有的 claude / codex pane，列出接管指令 |
| `fleet discover --adopt` | 掃到的 pane 全部接管、自動取名（跳過指揮官那格與已登記的） |
| `fleet adopt <名字> <pane> [socket]` | 單獨接管一格（**永不 kill**）；`pane` 直接複製 `fleet discover` 印的那行 |
| `fleet who <id>` | 這個 id 是哪個視窗 |
| `fleet rename <舊> <新>` | 改名 |
| `fleet forget <id>` | 解除登記（不 kill pane） |
| `fleet ls` | registry 清單 |
| `fleet gc` | 清理 `state.json` 裡的孤兒項目 |

### 新開艦隊

| 指令 | 做什麼 |
|---|---|
| `fleet up [--cc N] [--cx M] [-C dir]` | 新開一組，預設 `--cc 2 --cx 1`。**已有一組就自動再開獨立的一組**，開完直接 attach 進去（`--no-attach` 可關） |
| `fleet add <kind> [dir]` | 動態增援一隻。`kind` 是 adapter 名（內建 `cc` / `cx`） |
| `fleet attach` | 進 spawn 出來的 session |
| `fleet down [組名] [-y]` | 收攤：kill 新開的那組（並清掉登記）；**接管的 pane 與其登記都不動**。多組時會要你指名，`--all` 才全收 |

> `fleet down` 對 adopt 進來的 worker 是**完全不碰**——pane 不 kill，registry 那一列也留著。
> 想解除登記用 `fleet forget <id>`。

### 派工與溝通

| 指令 | 做什麼 |
|---|---|
| `fleet send <id> "文字"` | 送訊息（也可從 stdin） |
| `fleet bcast "文字"` | 廣播給全體 |
| `fleet task <id> <brief>` | 派正式任務（送短訊指向 brief 檔） |
| `fleet peek <id> [行數]` | 讀 worker 畫面（預設 40 行） |
| `fleet wait <id> [秒]` | 等 worker 回到 idle（預設最多 300 秒） |

`fleet task` 的 brief 解析順序，找到第一個存在的就用：

1. `<brief>` 當成路徑直接用（相對或絕對都可以）
2. `$FLEET_TASKS/<brief>`
3. `$FLEET_TASKS/<brief>.md`

所以 `fleet task cc1 refactor-auth` 會找到 `$FLEET_TASKS/refactor-auth.md`，
而 `fleet task cc1 ./notes/adhoc.md` 直接用你給的路徑。三個都不存在就報錯，不會亂送。

> **`fleet send` / `fleet task` 不做送達回讀驗證。** 它們走 bracketed paste 送出，
> 由你當場看畫面確認。這也是為什麼兩者都會提醒你 `fleet peek` ——
> 送出 ≠ 有在跑，見 [pitfalls #6](docs/pitfalls.md#6-長訊息讓-codex-卡在-pasted-content而-send-回報成功)。
> 帶回讀驗證的是 watcher 通知指揮官那條路徑（`send_verified`）。

### 報告與 watcher

| 指令 | 做什麼 |
|---|---|
| `fleet reports [N]` | 列最近 N 份報告 |
| `fleet lint <報告檔>` | 報告四節 schema 驗證 |
| `fleet watch start\|stop\|restart\|status\|log` | 回報閉環 watcher |

### 設定

| 指令 | 做什麼 |
|---|---|
| `fleet commander here` | 把「你現在坐的這格」設成指揮官（自動抓 `$TMUX_PANE`，不用查 `%NN`） |
| `fleet commander` | 顯示目前設定 |
| `fleet profile [<name>]` | 不帶參數＝列出；帶名字＝建立該 profile 並印出切換指令 |
| `fleet config` | 顯示生效中的設定與其來源（環境變數／設定檔／預設） |

> **切換 profile 是靠環境變數**，`fleet profile <name>` 只負責建立目錄並把指令印給你：
> ```bash
> export FLEET_PROFILE=work
> ```
> 這是刻意的——`fleet` 是短命行程，它改不了呼叫它的那個 shell 的環境。

---

## 指揮官 skill（Claude Code）

fleet 的價值一半在 CLI，一半在「指揮官 AI 知道怎麼用它」。
沒有這一步，你每開一個新 session 都要重新解釋一次
「你是指揮官、可以派工給其他 pane 裡的 AI」。

`install.sh` 會在偵測到 `~/.claude/skills/` 時，把
[`share/skills/fleet-commander/`](share/skills/fleet-commander/SKILL.md)
**symlink** 過去（不是複製——fleet 升級時 skill 內容自動跟著更新）。

```bash
./install.sh              # 有 ~/.claude/skills/ 就裝，沒有就完全跳過
./install.sh --skill      # 一定要裝（目錄不存在也會建）
./install.sh --no-skill   # 一定不裝
```

目標路徑已經有東西而且不是安裝器建的 → **絕不覆寫**，只印出手動指令讓你自己決定。

skill 本體只有一頁（開工三件事、派工、看板讀法、三條硬規則），
刻意不塞完整 SOP。指揮官 AI 需要細節時自己跑：

```bash
fleet protocol       # 印出完整指揮官協定（= docs/commander-protocol.md）
```

這樣協定只有一份、不會有副本分岔，skill 也不用寫死安裝路徑。

其他 harness（Codex、Cursor…）沒有 skill 機制的，把
`fleet protocol` 的輸出貼進該工具的系統提示或 `AGENTS.md` 即可。

---

## 設定

### 環境變數

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
| `FLEET_AUTO_FORGET` | `1` | worker 被 exit 掉後自動從 registry 移除（`0` 關閉） |
| `FLEET_FORGET_STRIKES` | `3` | 連續幾輪確認 pane 不見才移除。tmux server 問不到時一律不算數 |
| `FLEET_MAIN_PANE_WIDTH` | `60%` | 艦隊畫面左邊主格的寬度（`main-vertical` 版面） |
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

**以上全部**都可以在 `config.env` 覆寫，也可以用真實環境變數覆寫。

優先權：**真實環境變數 > `config.env` > 內建預設**。
想知道某個值現在是誰決定的，跑 `fleet config`——它會逐項標出來源。

> `fleet config` 目前不列 `FLEET_CONFIG`、`FLEET_LIBDIR`、`FLEET_LINT_REPORTS` 三項：
> 前兩者分別顯示在該指令的檔頭與 `fleet version`，`FLEET_LINT_REPORTS` 只在 watcher 內就地取用。
> 三者都仍可正常覆寫。

### `config.env` 格式

`KEY=value`，一行一條，`#` 開頭是註解：

```sh
# ~/.config/fleet/config.env
FLEET_REPORTS=$HOME/work/reports
FLEET_TASKS=$HOME/work/tasks
FLEET_SOCKET=agents
FLEET_IDLE_SECS=120
```

載入時的三條安全規則：

1. key 必須是 `FLEET_` 開頭的大寫名稱——設定檔改不了 `PATH` / `LD_PRELOAD`
2. 值不得含反引號或 `$(`——設定檔不是任意程式碼執行的入口
3. 已經存在於環境的 key 一律不覆寫——真實環境變數優先

不符合的行會被**拒絕載入並印警告**，不會靜默忽略。

### 執行期資料佈局

```text
$FLEET_HOME/profiles/$FLEET_PROFILE/
  registry        id<TAB>socket<TAB>pane<TAB>kind
  commander       socket<TAB>pane
  state.json      單一狀態檔（去重／熔斷／worker 轉換）
  watch.log       結構化日誌（JSON Lines）
  watch.pid       daemon pid
  locks/          mkdir 原子鎖
```

沒有任何 `.notified` / `.hash` 散檔，全部進 `state.json`。

### 支援新的 worker CLI

訊號比對規則是**資料不是程式碼**。新增一種 worker CLI ＝ 新增一個 `adapters/<kind>.conf`，
不需要改任何程式碼：

```ini
name=claude
command=claude
detect=bypass permissions|Claude Code|for shortcuts|esc to interrupt
ready=for shortcuts|bypass permissions on
busy=esc to interrupt|without interrupting|shell still running|Running [0-9]+ shell
stuck=Press up to edit queued messages|\[Pasted Content [0-9]+ chars\]
asking=Do you want|❯ 1\.|Ready to submit
ctx=◔ *([0-9]+)%
trust=trust this folder|Do you trust
```

值是 ERE（同時給 `grep -E` 與 python `re` 用，所以只能用兩者的交集語法）。

---

## 設計取捨

有幾個地方是**刻意偏離原始規格**的，寫在這裡免得日後有人「順手改回去」。

### 設定檔用 `config.env`（`KEY=value`），不用 TOML

原始規格寫的是 `~/.config/fleet/config.toml`。實作**沒有照做**，理由：

- **bash 沒有可靠的 TOML parser。** 這個工具的核心是 bash（tmux I/O 只能在 bash 做），
  設定必須在 bash 側就能讀。自己用 `sed` / `awk` 拼一個 TOML parser 是 bug 工廠——
  多行字串、陣列、巢狀 table、跳脫規則，每一項都是一個等著咬人的邊界情況。
- **引入相依只為了讀設定不划算。** 要正確解析 TOML 就得依賴外部工具或 python 套件，
  而這個工具現在的相依只有 tmux + python3 + bash 3.2，全是系統內建。
- **設定內容本來就是扁平的。** 全部是 `FLEET_*` 的純量。TOML 的表達力用不上，
  只是多付 parser 的代價。
- **`KEY=value` 可以被安全地驗證。** 三條規則（key 白名單、值禁止命令替換、環境變數優先）
  用幾行 bash 就能寫對，而且看得懂——這比一個「大致能動」的 TOML parser 值得信任。

代價是設定檔不能有結構化資料。目前不需要；真的需要的那天，該長結構的東西
（例如 adapter 規則）已經有自己的檔案格式了。

### 其他刻意的選擇

| 選擇 | 替代方案 | 為什麼不選替代方案 |
|---|---|---|
| 盯報告檔落地 | worker 主動回報 | 已證明會失敗——worker 會忘、會卡、context 會爆 |
| pane id `%NN` | `session:win.pane` 座標 | 座標會位移，派工**靜默**送錯人 |
| adapter 是資料檔 | 規則寫在程式碼 | 同一份 regex 曾複製到 4 個檔案並漂移 |
| 單一 `state.json` | `.notified` / `.hash` 散檔 | 檔名轉碼會撞 key，中文報告永久靜音 |
| bash + python3 | 重寫成單一語言 | tmux I/O 只能 bash；純函式邏輯要能測 |

每一條的完整推導在 [docs/design.md](docs/design.md)。

---

## 需求

| 項目 | 版本 |
|---|---|
| tmux | ≥ 3.0 |
| python3 | ≥ 3.8 |
| bash | 3.2+（macOS 內建那個就夠） |

沒有其他相依。純函式邏輯放 python3（可測），tmux I/O 留在 bash。

---

## 文件

| 文件 | 內容 |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | 實作契約：目錄佈局、路徑、`state.json` schema、送訊協定 |
| [docs/design.md](docs/design.md) | 為什麼這樣設計——各項核心決策的理由與失敗經驗 |
| [docs/pitfalls.md](docs/pitfalls.md) | **血淚細節**。踩過的每一個坑：症狀／根因／修法。改動前務必讀 |
| [docs/commander-protocol.md](docs/commander-protocol.md) | 給「指揮官 AI」讀的派工 SOP（`fleet protocol` 印同一份） |
| [share/skills/fleet-commander/SKILL.md](share/skills/fleet-commander/SKILL.md) | Claude Code 用的一頁版指揮官 skill |
| [docs/migration.md](docs/migration.md) | 從舊版個人 fleet 佈局遷移 |

---

## 明確不做

- ❌ 不改成「worker 主動回報」——已證明會失敗，盯報告檔落地是核心決策
- ❌ 不重寫成其他語言
- ❌ 不自動修改使用者的 shell rc
- ❌ 不加自動合併 PR——合併是人的決定
- ❌ 不注入使用者的 AI CLI 設定檔

---

## 授權

MIT
