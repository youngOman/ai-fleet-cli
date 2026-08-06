# 從舊版個人 fleet 遷移

> 這份是給**已經在用舊版個人 fleet 腳本**的人看的。
> 全新安裝的使用者不需要讀這篇——直接看 [README](../README.md) 就好。

舊版是單一使用者的個人工具：路徑寫死在 `$HOME` 底下、狀態散落成一堆小檔案、
指揮官設定只有一欄。產品化之後這些都變了。

**好消息是：遷移是加法不是減法。** `install.sh --migrate` 會把舊資料搬到新位置，
**但不刪舊檔**——出事你隨時可以退回去。

---

## 1. 佈局對照

### 舊佈局

```text
~/.claude/fleet/
  fleet                 主 CLI
  watcher               回報閉環守護行程
  mon                   即時看板
  board                 舊版看板
  registry              id<TAB>socket<TAB>pane<TAB>kind
  commander             指揮官 pane id（單欄，例如 %12）
  .state/
    rep-<轉碼檔名>.notified
    rep-<轉碼檔名>.hash
    worker-<id>.wasbusy
    worker-<id>.idle_notified
    …
    watch.log
    watch.pid

~/dev-docs/
  reports/              完成報告
  tasks/                派工單
```

程式碼與執行期資料**混在同一個目錄**，而且那個目錄還是 AI CLI 的設定目錄。

### 新佈局

**程式碼**（git repo，可更新、可刪除重裝）：

```text
<你 clone 的地方>/ai-fleet-cli/
  bin/ lib/ libexec/ adapters/ share/ completion/ …
```

**執行期資料**（`$FLEET_HOME`，預設 `${XDG_DATA_HOME:-$HOME/.local/share}/fleet`）：

```text
$FLEET_HOME/profiles/default/
  registry        id<TAB>socket<TAB>pane<TAB>kind
  commander       socket<TAB>pane          ← 兩欄！
  state.json      單一狀態檔
  watch.log       JSON Lines
  watch.pid
  locks/
```

**設定**（`$FLEET_CONFIG`，預設 `${XDG_CONFIG_HOME:-$HOME/.config}/fleet/config.env`）

**報告與派工單**（預設 `$HOME/fleet/reports`、`$HOME/fleet/tasks`）

程式碼、執行期狀態、使用者設定、產出物，四者分開。

---

## 2. 怎麼遷移

### 步驟 1：先健檢

```bash
fleet doctor
```

`doctor` 會偵測舊佈局。看到舊目錄存在、而新的 profile 目錄還沒建立時，
它會提示你可以遷移，並列出偵測到的舊檔。

**`doctor` 只讀不寫**，跑它不會改任何東西。

### 步驟 2：先看它會做什麼

```bash
./install.sh --migrate --dry-run
```

`--dry-run` 只印計畫、不寫任何檔案，包含 registry 的內容預覽。看過再動手。

> 舊目錄不在預設位置（`~/.claude/fleet`）的話，用環境變數指定來源：
> ```bash
> FLEET_OLD_DIR=~/somewhere/fleet ./install.sh --migrate --dry-run
> ```

### 步驟 3：遷移

```bash
./install.sh --migrate
```

它會做的事：

| 舊 | 新 | 動作 |
|---|---|---|
| `<舊目錄>/registry` | `$FLEET_HOME/profiles/default/registry` | 複製；**pane 欄不是 `%NN` 的列會被擋下不搬**（見下） |
| `<舊目錄>/commander` | `$FLEET_HOME/profiles/default/commander` | **轉換成兩欄** |
| `<舊目錄>/.state/*` | — | **刻意不遷移**（見 3.2） |

遷移目標固定是 **`default` profile**。

**舊檔一個都不刪。** 遷移可以重跑；確認新版跑順了，你要自己手動清。

#### registry 裡的座標列不會被搬過去

舊 registry 若有 pane 欄寫成 `fleet:cc1` 或 `0:1.2` 這種 session/window 名稱或座標的列，
`--migrate` 會**列出它們並拒絕搬遷**，因為新版只接受穩定 pane id。
座標會因為別人插一格而整排位移，派工就送錯人——把它搬進來等於把 bug 一起搬。

被擋下的那幾隻請重新登記（pane 還活著的話）：

```bash
fleet discover                    # 掃出現有 pane 與它們真正的 %NN
fleet adopt <id> <%NN> [socket]
```

### 步驟 4：確認

```bash
fleet doctor            # 應該不再提示舊佈局
fleet ls                # registry 內容應該跟以前一樣
fleet config            # 確認各項路徑指到你預期的地方
fleet watch restart     # 用新的 state.json 重啟 watcher
```

`fleet watch status` 看幾分鐘，確認沒有異常的通知洗版（見下面第 4 節）。

---

## 3. 重大行為改變

### 3.1 `commander` 從一欄變兩欄

**舊**：只有 pane id。

```text
%12
```

**新**：`socket<TAB>pane`。

```text
-	%12
```

（`-` 表示預設 socket；spawn 出來的指揮官會是 `agents` 之類的實際 socket 名。）

**為什麼改**：舊版通知指揮官那條路徑用的是**裸 `tmux`**（沒帶 `-L`）。
指揮官只要不在預設 socket，那個 pane id 在預設 socket 上根本不存在，
tmux **靜默失敗**——通知全部消失而且沒有錯誤訊息。
現在所有 tmux 呼叫都強制帶 socket，所以 commander 必須記錄 socket。

`--migrate` 會自動把單欄轉成 `-<TAB><舊值>`。
如果你的指揮官不在預設 socket，遷移後要自己更正：

```bash
fleet commander %12 agents
```

不確定的話直接跑 `fleet commander` 看目前設定。

### 3.2 `.state/` 散檔不再使用，而且**刻意不遷移**

`rep-*.notified`、`rep-*.hash`、`worker-*.wasbusy` 這些檔案**新版完全不讀不寫**，
狀態全部在 `state.json`。

**`--migrate` 不會把它們搬進 `state.json`。** 這是刻意的，兩個理由：

1. **格式已改。** 新版沒有 `.notified` / `.hash` 的概念，全部收進單一 JSON。
2. **搬進來等於把 bug 一起搬。** 舊 key 用 `tr -c 'A-Za-z0-9_.-' '_'` 逐 byte 轉碼，
   **中文主題會被整串壓成底線**，兩份同日同 worker 的中文報告會撞 key、
   後者**永久靜音**。轉碼是單向的，還原不回來——所以正確做法是丟掉重建，不是修補。

改用單一 `state.json` 的完整理由見 [design.md 第 8 節](design.md#8-狀態為什麼集中在單一-statejson)，
另外還有：一次通知要更新兩個檔、中途被 kill 就留下半殘狀態（現在是 temp + rename 原子寫），
以及散檔清不掉（現在 `fleet gc` 一次清乾淨）。

**不會因此洗版**：第一次啟動 watcher 時 `state.json` 是空的，
但 backfill 保護會把「首次見到且 mtime 超過 `FLEET_BACKFILL_SECS`（預設 600 秒）的舊報告」
只建基準線、不發通知。詳見下面第 4 節。

> 想連剛剛那幾份**新**報告也一起靜音（例如你正在搬機器、不想被歷史打擾），
> 把 `FLEET_BACKFILL_SECS` 調小再啟動一次即可。

### 3.3 報告目錄預設改變

| | 路徑 |
|---|---|
| 舊 | `~/dev-docs/reports`（寫死） |
| 新 | `$HOME/fleet/reports`（`FLEET_REPORTS` 可覆寫） |

派工單同理：`~/dev-docs/tasks` → `$HOME/fleet/tasks`（`FLEET_TASKS`）。

**想維持原本的位置**，設環境變數就好，不必搬檔：

```sh
# ~/.config/fleet/config.env
FLEET_REPORTS=$HOME/dev-docs/reports
FLEET_TASKS=$HOME/dev-docs/tasks
```

或者直接 export（優先權高於 config.env）：

```bash
export FLEET_REPORTS="$HOME/dev-docs/reports"
export FLEET_TASKS="$HOME/dev-docs/tasks"
```

改完跑 `fleet config` 確認生效，然後 `fleet watch restart`。

### 3.4 訊號規則從程式碼變成資料檔

舊版的忙碌／卡住／等答 regex 直接寫在腳本裡，而且被複製到了 4 個檔案（然後漂移）。
新版集中在 `adapters/cc.conf` / `adapters/cx.conf`。

**如果你以前自己改過腳本裡的 regex**，那些修改不會被遷移——
去對應的 `.conf` 檔重新加一次。好處是這次只要改一個地方。

順帶一提，舊版寫死在 watcher 裡的**自動應答**（codex 的「Retry with a faster model」選 2）
現在也是 adapter 資料：

```ini
autoreply1_match=Retry with a faster model
autoreply1_keys=2
```

`adapters/cx.conf` 已內建這一條，行為與舊版相同。你有別的攔截框要自動回答，
加 `autoreply2_match` / `autoreply2_keys` 即可（`N` 支援 1–9）。

### 3.5 `watch.log` 從純文字變 JSON Lines

舊的 `watch.log` 是人類可讀的純文字。新的是 JSON Lines（一行一個事件物件）。

`fleet watch log` 會幫你格式化成可讀形式。
舊的 log 檔不會被轉換，也不會被刪，`--migrate` 直接留在原地。

### 3.6 支援多 profile

新增的能力，不影響既有行為。
所有執行期資料都在 `$FLEET_HOME/profiles/<name>/` 底下，
遷移進來的東西一律進 `default`。

```bash
fleet profile              # 列出所有 profile
fleet profile work         # 建立 work profile，並印出切換用的指令
export FLEET_PROFILE=work  # 切換是靠環境變數
```

想同時維護兩支不同的艦隊（例如兩個專案各一組 worker）時才需要用到。

### 3.7 門檻全部可調

舊版的秒數門檻寫死在 watcher 裡。新版全部是環境變數，可在 `config.env` 覆寫：

`FLEET_SEND_DELAY` / `FLEET_POLL_SECS` / `FLEET_STABLE_SECS` / `FLEET_IDLE_SECS` /
`FLEET_STUCK_SECS` / `FLEET_QUIET_AFTER_REPORT` / `FLEET_BACKFILL_SECS` /
`FLEET_MAX_ATTEMPTS` / `FLEET_REPORT_COOLDOWN_SECS` / `FLEET_LINT_REPORTS`

預設值與舊版寫死的值相同，所以**不設定就等於維持舊行為**。
各項意義見 [README 的環境變數表](../README.md#環境變數)，
目前生效值與來源用 `fleet config` 查。

---

## 4. 遷移後第一次啟動 watcher 會發生什麼

**不會洗版。** backfill 保護會處理。

首次見到、且 mtime 已超過 `BACKFILL_SECS`（600 秒）的報告檔，
watcher 只寫入基準線、**不發通知**。
所以就算 `state.json` 完全對不上你的歷史報告，也只會安靜地建一次基準線。

（舊版沒有這個保護，實際發生過首次啟動一口氣洗版 6 則。
見 [pitfalls #13](pitfalls.md#13-watcher-首次啟動會重播整個報告目錄)。）

不放心的話，可以先確認一遍：

```bash
fleet watch start
fleet watch log           # 看有沒有非預期的 notify 事件
```

---

## 5. 遷移後可以清掉什麼

**確認新版穩定跑了幾天再動手。** 這些都不急。

```bash
# 舊的散狀態（新版完全不讀）
rm -rf ~/.claude/fleet/.state

# 舊的執行檔（如果你不打算退回舊版）
rm ~/.claude/fleet/fleet ~/.claude/fleet/watcher ~/.claude/fleet/mon ~/.claude/fleet/board

# 舊的 PATH symlink（install.sh 會裝新的）
# 先確認它指向哪裡再刪
ls -l ~/.local/bin/fleet
```

`registry` 和 `commander` 建議留著當備份，它們很小。

---

## 6. 怎麼退回舊版

`--migrate` 不刪舊檔，所以退回很單純：

1. `fleet watch stop`（停掉新版 watcher）
2. 把 PATH 上的 `fleet` 指回舊的腳本
3. 啟動舊版 watcher

新版寫的 `state.json` 對舊版來說不存在，舊版會繼續讀它自己的 `.state/` 散檔。
兩邊的狀態是獨立的——**不要同時跑兩個 watcher**，否則每則通知會送兩次。
