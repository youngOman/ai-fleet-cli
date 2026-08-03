# 血淚細節

> **這是這個 repo 最有價值的一份文件。**
> 每一條都是實際踩過才寫下來的。移植、重寫、「順手優化」之前，一條都不能少。
>
> 每條的格式：**症狀 → 根因 → 修法 → 對應機制**。
> 「對應機制」指出這條防呆現在活在程式碼的哪裡——動那段程式前，先回來讀這條。

---

## 目錄

**送訊到 TUI**
1. [pane 在 copy-mode 時 `send-keys` 被整包吃掉](#1-pane-在-copy-mode-時-send-keys-被整包吃掉)
2. [TUI composer 收字有延遲，Enter 按在空框上](#2-tui-composer-收字有延遲enter-按在空框上)
3. [前景是 shell 時送出去等於丟掉](#3-前景是-shell-時送出去等於丟掉)
4. [絕對不能插隊使用者正在打的字](#4-絕對不能插隊使用者正在打的字)
5. [驗證送達只能 grep 短單號](#5-驗證送達只能-grep-短單號)
6. [長訊息讓 codex 卡在 `[Pasted Content]`，而 send 回報成功](#6-長訊息讓-codex-卡在-pasted-content而-send-回報成功)
7. [連續驗不到要熔斷，寧漏勿轟](#7-連續驗不到要熔斷寧漏勿轟)
8. [訊息偶發蒸發（已知未解）](#8-訊息偶發蒸發已知未解)

**狀態判定**
9. [忙碌判定不能抓 spinner 動詞](#9-忙碌判定不能抓-spinner-動詞)
10. [「忙碌中訊息排隊」不是卡住](#10-忙碌中訊息排隊不是卡住)
11. [worker 顯示閒置不代表沒成果](#11-worker-顯示閒置不代表沒成果)
12. [pane 太窄讀不到結論](#12-pane-太窄讀不到結論)

**watcher 與狀態**
13. [watcher 首次啟動會重播整個報告目錄](#13-watcher-首次啟動會重播整個報告目錄)
14. [報告檔名轉碼會撞 key，讓報告永久靜音](#14-報告檔名轉碼會撞-key讓報告永久靜音)
15. [通知指揮官也要帶 socket](#15-通知指揮官也要帶-socket)

**worker 生命週期**
16. [不要 kill 卡死的 codex 程序](#16-不要-kill-卡死的-codex-程序)
17. [context 會耗盡，交接靠報告](#17-context-會耗盡交接靠報告)
18. [別派需要開互動子程式的活](#18-別派需要開互動子程式的活)
19. [沒人回答的攔截框會廢掉一整晚](#19-沒人回答的攔截框會廢掉一整晚)

**定址與環境**
20. [pane 座標會位移，派工送錯人](#20-pane-座標會位移派工送錯人)
21. [macOS locale 讓 sed / grep 噴 illegal byte sequence](#21-macos-locale-讓-sed--grep-噴-illegal-byte-sequence)
22. [`-w` 需要真 TTY](#22--w-需要真-tty)
23. [同一 session 掛兩個 client 會同步切 window](#23-同一-session-掛兩個-client-會同步切-window)
24. [bash 3.2：變數後面緊接非 ASCII 字元會吃掉一個 byte](#24-bash-32變數後面緊接非-ascii-字元會吃掉一個-byte)

**工作流**
25. [「等價執行」一律當成沒做](#25-等價執行一律當成沒做)
26. [APPROVED ≠ 可合併](#26-approved--可合併)
27. [重試上限 2：連錯兩次就是方法錯了](#27-重試上限-2連錯兩次就是方法錯了)

---

## 送訊到 TUI

### 1. pane 在 copy-mode 時 `send-keys` 被整包吃掉

**症狀**
`tmux send-keys` 執行成功、回傳 0，但 worker 的輸入框完全沒東西。
重試幾次也一樣。回頭看那格 pane，畫面右上角有 `[12/300]` 之類的捲動指示。

**根因**
使用者捲動畫面、或用滑鼠選字，都會讓 pane 進入 **copy-mode**。
copy-mode 下所有按鍵是**捲動與選取的操作**，不是輸入——
`send-keys` 送進去的每一個字都被當成 copy-mode 的快捷鍵吃掉了。
tmux 本身不認為這是錯誤，所以 exit code 是 0。

**修法**
送之前無條件先取消 copy-mode：

```bash
tmux -L "$socket" send-keys -t "$pane" -X cancel
```

不在 copy-mode 時這個指令是 no-op，成本極低，所以不用先判斷、直接送。

**對應機制**
`lib/tmuxio.sh :: send_verified` 第 1 步（`pane_in_mode` → `send-keys -X cancel`）。

---

### 2. TUI composer 收字有延遲，Enter 按在空框上

**症狀**
訊息內容有出現在輸入框，但沒被送出——或者更詭異：送出了一個空訊息，
worker 回你「我沒看到你的問題」。

**根因**
AI CLI 的輸入框是 TUI 元件，不是終端機原生的行編輯器。
`send-keys -l` 把字元灌進去之後，TUI 需要一點時間處理事件、渲染、更新內部緩衝。
在這之前就送 Enter，TUI 會拿當下（還是空的）緩衝去 submit。

**修法**
`send-keys -l` 之後 sleep 一段時間，再送**獨立的** Enter：

```bash
tmux -L "$socket" send-keys -t "$pane" -l -- "$msg"
sleep "${FLEET_SEND_DELAY:-1}"
tmux -L "$socket" send-keys -t "$pane" Enter
```

不要用 `send-keys -l "$msg" Enter` 一次送完——那樣中間就沒有延遲了。

**對應機制**
`lib/tmuxio.sh :: send_verified` 第 4–6 步；延遲長度由 `FLEET_SEND_DELAY`（預設 1 秒）控制。

---

### 3. 前景是 shell 時送出去等於丟掉

**症狀**
watcher log 顯示通知送出了，但指揮官從沒收到。
去看那格 pane，發現 AI CLI 剛剛重啟／崩潰／被 `/exit`，前景是一個乾淨的 shell prompt。

**根因**
訊息確實送進去了——送進了 **shell**。它變成一行還沒按 Enter 的指令，
或者更糟，被 shell 當指令執行了。無論如何，AI 沒收到。

而如果這時把它記成「已通知」，那份報告就**永遠不會再被通知一次**了。

**修法**
送之前檢查前景程式是不是預期的 AI CLI（比對 adapter 的 `detect` / `ready` 訊號）。
不是的話——

- **不送**
- **不記帳**（不寫 `notified_at`、不累加 `attempts`）
- 直接 return，下一輪重試

「不記帳」是這條的重點。這不是失敗，是**環境暫時不允許**，兩者要分開處理。

**對應機制**
`lib/tmuxio.sh :: tui_ready` → `send_verified` 第 2 步，回傳碼 `3`。
watcher 收到 `3` 不呼叫 `record-report`。

---

### 4. 絕對不能插隊使用者正在打的字

**症狀**
使用者正在跟指揮官打字，打到一半，一則通知從天而降插進句子中間：

```text
❯ 幫我看一下共📥 cc1 交報告：…享目錄的權限
```

「共享」被切成「共」+ 通知 + 「享」。這句話送出去指揮官讀到的是垃圾。
使用者根本沒辦法好好跟指揮官講話。

**根因**
watcher 是背景行程，它不知道人類正在鍵盤前面打字。
`send-keys` 會直接插在游標位置。

這條的嚴重性容易被低估——它不只是「訊息醜掉」，
而是**讓使用者無法使用這個系統**。使用者會直接把 watcher 關掉。

**修法**
送之前偵測 composer 是否為空：抓 composer 行（`❯` 開頭那行），
看提示符後面是否有非空白字元。有字 → 使用者正在打字 → **延後到下一輪**。

同樣地：**不記帳、不算失敗**。使用者打完字自然會空出來。

**對應機制**
`lib/tmuxio.sh :: composer_busy` → `send_verified` 第 3 步，回傳碼 `2`。
watcher 收到 `2` 同樣不呼叫 `record-report`。

---

### 5. 驗證送達只能 grep 短單號

**症狀**
明明訊息好好地出現在畫面上，驗證邏輯卻總是判定「驗不到」，
於是重送、重送、重送，最後熔斷。指揮官收到三則一模一樣的通知。

**根因**
`capture-pane` 回讀的是**渲染後的畫面**。TUI 會依 pane 寬度折行，
一句話被切成好幾段，中間插入換行、縮排、有時還有框線字元。

```text
│ 📥 cc1 交報告：20260803-1420-cc1-refac  │
│ tor-auth.md (r1754209200)               │
```

拿原始訊息全文去 `grep -F`，**必定失敗**。

**修法**
每則通知都帶一個**短單號**，短到不可能被折行切開（例如報告訊號用 `r<mtime>`）。
驗證時只 grep 這個短單號：

```bash
tmux -L "$socket" capture-pane -p -t "$pane" -S -150 | grep -qF "$tag"
```

回讀範圍要往上抓（`-S -150`），因為訊息送出後畫面可能已經捲動。

**對應機制**
`lib/tmuxio.sh :: send_verified` 第 7 步；短單號由呼叫端（watcher）產生並傳入。

---

### 6. 長訊息讓 codex 卡在 `[Pasted Content]`，而 send 回報成功

**症狀**
`fleet send` 回報「已派給 cx1」。過了十分鐘，worker 一動也不動。
`fleet peek cx1` 一看，輸入框底部寫著：

```text
› [Pasted Content 3412 chars]
```

內容確實貼進去了，但**沒有執行**。按 Enter 沒用、按 `C-m` 沒用（都實測過）。

這是**假訊號**：CLI 說派了，實際上什麼都沒跑。
同一天在三個不同的 codex worker 上重現。claude worker 沒有這個問題，但沒理由賭。

**根因**
codex 的輸入框對超過某個長度的貼上內容會折疊成一個 attachment-like 的節點，
需要額外的互動才會展開／送出。而 `send-keys` 的成功只代表**按鍵送到了 tmux**，
跟 TUI 有沒有正確處理完全無關。

**修法**

1. **派正式任務一律用 `fleet task`**——把長內容寫成檔案，只送一句短訊指向它：
   ```bash
   fleet task cx1 refactor-auth     # 送短訊指向 $FLEET_TASKS/refactor-auth.md
   ```
   完全繞開長度問題，順帶讓派工內容有版本可回溯。

2. **不得已要送長內容給 codex 時，拆成 2～3 則短訊連送**（單段落、少換行）。

3. **每次派完必須驗證真的開跑**，不要假設送出＝開始：
   ```bash
   fleet send cx1 "…短訊…"
   sleep 4
   fleet peek cx1 6        # 要看到它真的在動才算數
   ```

4. **已經卡住的救法**（Enter / `C-m` 無效，實測過）：
   ```bash
   tmux -L "$socket" send-keys -t "$pane" C-c    # 中斷
   tmux -L "$socket" send-keys -t "$pane" C-u    # 清空輸入框
   # 確認回到 placeholder 後，改用短訊重送
   ```

5. **卡住期間 worker 的前一件工作可能已經完成。**
   重派前先 `peek` 讀它上一則回報——曾經差點把已完成的文件任務當成白跑，整個重來。

**對應機制**
`bin/fleet :: task` 子命令；`adapters/cx.conf` 的 `stuck=` 規則含
`\[Pasted Content [0-9]+ chars\]`，watcher 會據此發 🚧 卡住通知。

---

### 7. 連續驗不到要熔斷，寧漏勿轟

**症狀**
某個 pane 因為未知原因永遠驗不到（例如 pane 寬度極窄、或 TUI 有 bug），
watcher 每輪重送一次，一小時後指揮官的輸入框裡塞了 1200 則相同通知。

**根因**
重試沒有上限。

**修法**
每份報告記 `attempts`，連續 `--max-attempts`（預設 3）次驗不到就**放棄不再送**。

放棄的成本其實很低——**報告檔本來就還在報告目錄裡**，
指揮官跑 `fleet reports` 隨時看得到。漏一則通知遠比洗版 1200 則好。

注意只有回傳碼 `1`（驗不到）才累加 attempts。`2` / `3` 不算（見第 3、4 條）。

**對應機制**
`libexec/fleet-state :: plan-reports --max-attempts` 與 `record-report --result fail`。

---

### 8. 訊息偶發蒸發（已知未解）

**症狀**
`fleet send` 回報成功、驗證也過了，但過一會兒回去看 composer 是空的，
worker 從沒收到那則訊息。

**根因**
**未知。** 尚未找到穩定重現條件。

**修法（手動救援）**
依序執行通常可以救回：

```bash
tmux -L "$socket" send-keys -t "$pane" -X cancel
tmux -L "$socket" send-keys -t "$pane" C-u
tmux -L "$socket" send-keys -t "$pane" -l -- "$msg"
sleep 1
tmux -L "$socket" send-keys -t "$pane" Enter
```

**對應機制**
尚未加自動重試——在根因不明的情況下自動重試有洗版風險。
如果你能穩定重現，那是很有價值的 issue。

---

## 狀態判定

### 9. 忙碌判定不能抓 spinner 動詞

**症狀**
worker 明明在跑，看板顯示「閒置」，watcher 發出「⚠️ 閒置未交報告」假警報。
一天發好幾十則，指揮官學會了忽略警報——然後真的閒置時也被忽略了。

**根因**
第一版用 spinner 旁邊的動詞來判斷忙碌。問題是 **Claude Code 的 spinner 動詞是隨機的**：

```text
Metamorphosing…  Boondoggling…  Sautéed…  Synthesizing…
Churned…  Levitating…  Razzmatazzing…
```

這是一個開放集合，你窮舉不完。抓字必漏，漏了就誤報成閒置。

**假警報比沒警報更糟**——它會訓練使用者忽略所有警報，讓整個通知系統失去意義。

**修法**
改抓**結構性訊號**——那些跟 UI 狀態綁定、不是隨機文案的字串：

```text
esc to interrupt | without interrupting | shell still running
| Running [0-9]+ shell | ↓ *[0-9] | \([0-9]+m [0-9]+s | \([0-9]+s +[·•]
```

這些是「有東西正在跑，你可以中斷它」這個 UI 狀態的固定表現，不會隨機換詞。

**對應機制**
`adapters/<kind>.conf` 的 `busy=` 欄位。**不要把 spinner 動詞加回去**，
就算你看到一個新的也不要——加了就是走回頭路。

---

### 10. 「忙碌中訊息排隊」不是卡住

**症狀**
worker 正在認真幹活，watcher 一直發「🚧 卡住」。

**根因**
worker 忙的時候收到新訊息，CLI 會把訊息排隊並顯示
`Press up to edit queued messages`。這個字串也是 `stuck` 訊號的一部分。

但**這是正常行為**——它做完手上的事自然會消化佇列。

**修法**
卡住判定加一個硬性條件：**`stuck` 訊號持續超過門檻，而且 worker 非 busy**。

```text
stuck_matched && !busy && (now - stuck_since) > STUCK_SECS
```

busy 的時候有排隊訊息，一律不算卡住。

**對應機制**
`libexec/fleet-state :: worker-tick --busy --stuck`；
`--stuck 1` 且 `--busy 1` 時不會輸出 `notify-stuck`。

---

### 11. worker 顯示閒置不代表沒成果

**症狀**
看板上 `cc1` 是 😴 閒置。直覺反應是「它沒事做，派點活給它」。

**根因**
最常見的閒置原因不是「沒事做」，而是——**做完了但沒人去收**。

**修法**
把「閒置」讀成**「該去 peek 了」的訊號**，不是「該派工了」的訊號。

```bash
fleet peek cc1 60      # 先看它上一輪做了什麼
```

尤其在你剛派過工之後看到閒置，幾乎一定是做完了。
直接重派會讓它把已完成的工作重做一次。

**對應機制**
⚠️ 閒置未交報告 通知就是為了讓這件事自動化——
`worker-tick` 在 busy→idle 超過 `IDLE_SECS`（90）且距最後報告 > `QUIET_AFTER_REPORT`（300）秒時觸發。

---

### 12. pane 太窄讀不到結論

**症狀**
`fleet peek cc1 40` 讀回來一堆折行的碎片，worker 明明寫了完整結論，
你只看到被切爛的片段，或者被更新的畫面捲掉了。

**根因**
六格 pane 的佈局下，有些 pane 只有 60 幾字寬。
`capture-pane` 抓的是**渲染後畫面**，內容早就被折行與捲動破壞了。
scrollback 也有上限，長輸出直接消失。

**修法**
**這不是「worker 沒回報」的理由。**
這正是為什麼要有報告目錄——結論必須落地成檔案，不能只存在於 pane 畫面上。

- 派工單一律要求把報告寫到 `$FLEET_REPORTS/`
- `peek` 只用來看「它有沒有在動」「卡在哪」，不是用來讀成果
- 讀成果用 `fleet reports` 找檔案，然後直接讀檔

**對應機制**
`fleet task` 送出的短訊自動附帶回報協定（含報告路徑）；
`fleet lint` 驗證報告四節齊全。

---

## watcher 與狀態

### 13. watcher 首次啟動會重播整個報告目錄

**症狀**
`fleet watch start` 之後幾秒鐘內，指揮官的輸入框被灌進 6 則「📥 交報告」，
全都是幾天前的舊報告。實際發生過，一口氣洗版 6 則。

**根因**
watcher 的去重是靠 state 記錄「這份報告通知過了」。
全新啟動（或換報告目錄、或搬機器）時 state 是空的，
於是目錄裡**每一份歷史報告都是新的**。

**修法**
backfill 保護：首次見到、且 mtime 已經超過 `BACKFILL_SECS`（600）秒的檔案，
**只寫入基準線、不發通知**。

「首次見到」＋「已經放很久」＝ 這是歷史檔案，不是剛完工的成果。
剛寫好的報告 mtime 是幾秒前，不受影響，正常通知。

**對應機制**
`libexec/fleet-state :: plan-reports --backfill B`——它會就地寫入基準線並且不輸出該筆。

---

### 14. 報告檔名轉碼會撞 key，讓報告永久靜音

**症狀**
同一個 worker 同一天交的第二份中文主題報告，**完全沒有通知**。
檔案在、內容對、watcher 也活著，就是不發。

**根因**
舊版用散檔記狀態，要把報告檔名塞進檔名，所以做了
`tr -c 'A-Za-z0-9_.-' '_'` 逐 byte 轉碼。中文整串被壓成底線：

```text
20260803-1420-cc1-重構驗證.md  →  20260803-1420-cc1-_________.md
20260803-1430-cc1-補測試.md    →  20260803-1430-cc1-_________.md
```

時間戳不同還救得回來，但只要主題長度相同、時間戳又被截斷或相近，就會**撞 key**。
撞到的那份被當成「已通知過」，永久靜音。

**修法**
狀態改用單一 `state.json`，**key 直接用檔名原文，不做任何轉碼**。
JSON key 本來就吃 UTF-8，這個 bug 直接消失。

**對應機制**
`state.json` 的 `reports` 物件；`libexec/fleet-state` 是唯一寫它的程式。
詳見 [ARCHITECTURE.md](ARCHITECTURE.md) 第 5 節。

---

### 15. 通知指揮官也要帶 socket

**症狀**
worker 的通知全部正常，但指揮官從來沒被叫醒過。
watcher log 沒有錯誤，一切看起來都好。

**根因**
舊版通知指揮官那條路徑用的是**裸 `tmux`**（沒有 `-L`），
其他地方都有帶 socket。指揮官只要不在預設 socket（例如他也在 `agents` 裡），
那個 pane id 在預設 socket 上根本不存在——tmux 靜默失敗，watcher 不知道。

**修法**

- **所有 tmux 呼叫一律走同一個 wrapper，強制帶 socket。** 沒有例外。
- `commander` 檔改成**兩欄**：`socket<TAB>pane`，而不是只記 pane id。

**對應機制**
`lib/tmuxio.sh :: wtmux`；profile 目錄下的 `commander` 檔格式。

---

## worker 生命週期

### 16. 不要 kill 卡死的 codex 程序

**症狀**
codex worker 顯示「1 background terminal running」且完全不回應，
`C-c` / `/stop` / `C-u` 都救不回來。直覺是 `kill` 掉那個 process 讓它重啟。

**然後整格 pane 直接消失了。** 你少了一隻 worker，而且原本的工作目錄、
scrollback、context 全沒了。

**根因**
codex 是那個 pane 的前景程序（很可能就是 pane 的 shell 本身）。
它死了，tmux 認為這個 pane 的工作結束，就把 pane 收掉。

**修法**

- **不要 kill。** 接受這隻 worker 暫時廢了。
- 先 `fleet peek` 把它上一輪的成果讀出來（很可能已經完成了，見第 6 條第 5 點）。
- 需要的話 `fleet forget <id>` 解除登記，另外開一隻新的 adopt 進來。
- 真的要處理那個 pane，用 tmux 層級的操作，而且要有心理準備會失去它。

**對應機制**
`fleet down` 對 adopt 進來的 worker **完全不碰**——pane 不 kill，registry 那一列也留著；
它只 kill spawn 出來的 worker 並清掉那些登記。
`fleet forget` 才是解除登記的指令，而它同樣不動 pane 本體。
這是刻意的——**fleet 不擁有 adopt 進來的 pane**，沒有權力回收它們。

---

### 17. context 會耗盡，交接靠報告

**症狀**
worker 開始變笨：忘記前面講過的約定、重複問已經回答過的問題、
或者直接吐 context 相關的錯誤停擺。實測看過單一 worker 脹到 431k tokens。

**根因**
worker 是**常駐 peer**，不是每次派工都重開的 subagent。
context 會跨任務累積，只會漲不會消。

**修法**

1. **看板顯示剩餘 context，低於 20% 標紅。** 這是提前警告，不是事後補救。
2. 標紅之後就安排交接：讓它把當前狀態寫成報告 → `/clear` → 讓它讀自己剛寫的報告接續。

   **報告就是交接文件。** 這也是為什麼報告四節要求「殘留問題」那一節——
   它是給未來的自己看的。
3. 不要等到完全爆掉才處理。爆掉的時候它連「寫一份交接報告」都做不到。

**對應機制**
`adapters/<kind>.conf` 的 `ctx=` 欄位（含一個 capture group 取百分比）；
`libexec/fleet-mon` 據此上色。

---

### 18. 別派需要開互動子程式的活

**症狀**
worker 卡在一個巢狀 TUI 裡（例如它自己開了另一個 REPL、或跑了會進全螢幕介面的指令），
既不回應 `fleet send`，畫面也不是你認得的狀態。

**根因**
worker 本身就是一個互動 REPL 佔著 pane。
它再開一個互動子程式，就是 TUI 疊 TUI——你的 `send-keys` 會送到最外層還是最內層？
狀態判定的 regex 又該比對誰的畫面？兩邊都不對。

**修法**

- 派工單明確寫：**不要開互動子程式**，需要跑的東西一律用非互動模式
  （加 `--no-pager`、`--yes`、`CI=1`、把輸出導到檔案再讀等等）。
- 需要長時間跑的服務，讓它丟到背景並把 log 導到檔案，不要前景佔著。

**對應機制**
`share/task-template.md` 的邊界段落。

---

### 19. 沒人回答的攔截框會廢掉一整晚

**症狀**
早上回來看，worker 從昨晚某個時間點就沒動過。
畫面上是一個對話框：`Retry with a faster model?  1. Yes  2. No`。
它在等一個按鍵，等了八小時。

**根因**
這種停擺**三個通知訊號全都抓不到**：

| 訊號 | 為什麼沒觸發 |
|---|---|
| 📥 交報告 | 它沒完工，沒有報告 |
| 🚧 卡住 | `stuck` 抓的是輸入框卡訊（`[Pasted Content]` / 排隊訊息），對話框不是 |
| ⚠️ 閒置 | 會觸發，但只是把人叫醒去按一個鍵——**沒人在的時候等於沒用** |

閒置通知的設計前提是「有人會來收」。整晚無人看管時這個前提不成立。

**修法**
自動應答。watcher 巡邏時比對 adapter 定義的攔截框，命中就送出預設按鍵再送 Enter：

```ini
# adapters/cx.conf
autoreply1_match=Retry with a faster model
autoreply1_keys=2
```

`N` 從 1 到 9，可以定義多組。

三個必須注意的地方：

1. **答案要寫死在 conf，不能「一律選預設」。**
   上面那個框的預設是「好，降級到快模型」——它會**默默降低整批工作的品質**。
   選 `2`（不要）是一個策略決定，必須由使用者寫下來。
2. **命中的那一輪要跳過狀態判定。** 按鍵送出後畫面正在重繪，
   這時抓到的畫面既不能代表 busy 也不能代表 idle，硬判只會產生垃圾狀態轉換。
3. **規則不要寫太寬。** 自動應答只該處理**答案永遠一樣**的已知攔截框。
   需要看情況決定的問題（「要不要刪這個檔案？」）一律留給 `asking` 訊號讓人來看——
   規則寫寬了，等於讓 watcher 替你亂點確認鍵。

**注意**：自動應答**不做** `tui_ready` / `composer_busy` 檢查（不像通知路徑）。
它是對一個明確可見的對話框回答一個明確的鍵，而且要快。
代價是——如果你的 `autoreplyN_match` 剛好比對到使用者打字的內容，它會插隊。
**這是規則寫太寬的另一個懲罰**，pattern 請對準攔截框特有的字串。

**對應機制**
`libexec/fleet-watcher` 巡邏迴圈開頭（命中後 `continue`）；
`lib/signals.sh :: signals_autoreplies`；`adapters/<kind>.conf` 的 `autoreplyN_*` 欄位。

---

## 定址與環境

### 20. pane 座標會位移，派工送錯人

**症狀**
派工給 `cc1`，結果 `cx1` 開始動工，而且它動的是一個完全不相干的 repo。
最惡劣的是——**沒有任何錯誤**。訊息送出成功、驗證通過，只是送給了錯的人。

**根因**
早期 registry 記的是 `0:1.2` 這種 **session:window.index 座標**。
使用者在 window 中間插了一格新 pane，後面所有 index 整排位移，
registry 裡的對應關係全錯了。

**修法**
一律使用 **tmux 穩定 pane id（`%NN`）**。pane 活著，這個 id 就不變，
開關其他 pane 完全不影響。

好處不只是不會錯位——pane 死掉時 `%NN` 會直接查不到，
變成**明確的失聯狀態**，而不是靜默地指到別人身上。

`fleet discover` 直接吐 `%NN` 給你貼，不用自己數格子。

**對應機制**
`registry` 格式 `id<TAB>socket<TAB>pane<TAB>kind`；
`lib/registry.sh` 只接受 pane id 形式。

---

### 21. macOS locale 讓 sed / grep 噴 illegal byte sequence

**症狀**

```text
sed: RE error: illegal byte sequence
grep: illegal byte sequence
```

在 macOS 上處理 worker 畫面時出現，Linux 上一切正常。

**根因**
worker 畫面滿是 UTF-8 框線字元（`│ ─ ┌ ●`）與 emoji。
macOS 的 BSD `sed` / `grep` 在預設 locale（或 `LC_ALL` 沒設對）下
會把 multi-byte 序列當成非法輸入直接拒絕。

**修法**

1. **需要對畫面內容做複雜文字處理的部分，用 python3 寫。**
   這就是 `libexec/fleet-mon`、`libexec/fleet-state`、`libexec/fleet-lint`
   都是 python 的原因之一——python3 原生處理 UTF-8，不看 locale 臉色。
2. bash 側**只做簡單的存在性比對**（`grep -qE`），不做替換、不做擷取。
3. 需要在 bash 呼叫這類工具時，明確設定 locale。

**對應機制**
「純函式邏輯放 python3，tmux I/O 留在 bash」這條架構前提，
就是這條坑與「邏輯要可測」兩個理由的交集。

---

### 22. `-w` 需要真 TTY

**症狀**
`fleet mon -w` 在沒有 TTY 的環境（被 pipe、被重導向、在 AI CLI 裡用 `!` 前綴跑）
會**無限迴圈卡住，而且什麼都不吐出來**。你只能 `C-c`。

**根因**
持續刷新模式是一個 `while true` 迴圈，靠 ANSI escape 清畫面重繪。
沒有 TTY 時：ANSI 序列沒有意義、輸出被緩衝住不 flush、
而迴圈本身沒有結束條件——三件事加起來就是「卡死且沉默」。

**修法**
`isatty()` 偵測。非 TTY 時：

- **印一張快照就結束**（不進迴圈）
- 印一行提示告訴使用者為什麼沒有持續刷新

在 AI CLI 裡想看狀態，用不帶 `-w` 的 `fleet` 就好。

**對應機制**
`libexec/fleet-mon` 開頭的 `sys.stdout.isatty()` 檢查。

> **已知未解**：曾有一次在使用者的終端機新分頁回報 `-w` 「跑不出來」，
> 但互動 zsh／bash login／絕對路徑／`LC_ALL=C` 全測過都正常，**尚未重現**。
> 非 TTY 保護已經加上，但那次的根因未確認。

---

### 23. 同一 session 掛兩個 client 會同步切 window

**症狀**
你在 A 終端切到 window 2，B 終端的畫面**跟著跳走**。兩個人（或兩個分頁）沒辦法各看各的。

**根因**
tmux 的「當前 window」是 **session 層級的狀態**，不是 client 層級。
同一個 session attach 兩個 client，它們共用這個狀態。

**修法**
用**群組 session**——共用 window 集合，但各自有獨立的當前 window：

```bash
tmux new-session -t <既有session> -s <新名字>
```

**對應機制**
與 fleet 程式碼無關，但會影響你怎麼佈局艦隊。
`fleet up` 用獨立 socket（`FLEET_SOCKET`）就是為了讓 spawn 出來的 worker
跟你日常的 session 完全隔離，不會互相干擾。

---

### 24. bash 3.2：變數後面緊接非 ASCII 字元會吃掉一個 byte

**症狀**
一段看起來完全正常的 bash：

```bash
name=cc1
echo "$name」已就緒"
```

在 macOS 內建的 `/bin/bash`（3.2）底下，`set -u` 時直接噴：

```text
bash: name」: unbound variable
```

沒有 `set -u` 的話更糟——**靜默展開成空字串**，訊息裡的 id 就這樣消失了，
而且沒有任何錯誤。你會看到「fleet: 「」已就緒」這種輸出，然後懷疑人生。

**根因**
bash 3.2 判斷「變數名到哪裡結束」是**逐 byte** 掃的，而且它的字元類別判定
在 non-UTF-8-aware 的路徑上會把 multi-byte 字元的**第一個 byte** 當成合法的識別字字元。

全形引號 `」` 的 UTF-8 編碼是 `E3 80 8D`。bash 3.2 把 `E3` 吃進變數名，
於是它去找的是一個叫 `name\xe3` 的變數——那當然不存在。

這條在 bash 4+ 或 zsh 上**完全不會發生**，所以很容易在 Linux 上開發、
到 macOS 才炸。而 macOS 內建的 `/bin/bash` 就是 3.2（因為授權原因永遠不會升），
**這條一定會咬人。**

繁體中文文案首當其衝：`「」`、`（）`、`：`、`——` 全都是 multi-byte，
而這個專案的訊息幾乎全是中文。

**修法**
**變數一律寫 `${name}` 形式，不要裸寫 `$name`**，只要後面不是明確的空白或 ASCII 標點：

```bash
# 壞
echo "$name」已就緒"
echo "profile「$FLEET_PROFILE」只能用英數"

# 好
echo "${name}」已就緒"
echo "profile「${FLEET_PROFILE}」只能用英數"
```

`${...}` 的大括號明確標出變數名的邊界，byte 掃描不會越界。

三個附帶建議：

1. **不要只在「看起來會出事」的地方加大括號。** 規則要一致才記得住，
   而且文案是會被改的——今天後面是空白，明天有人加了一個「。」。
2. **`set -u` 要開。** 它把靜默的空字串變成明確的錯誤，這條坑至少會當場炸給你看。
3. **CI 要用 bash 3.2 跑一次。** 用 bash 5 測是測不出來的。

**對應機制**
「目標 shell 是 bash 3.2」這條架構前提；`lib/` 與 `bin/fleet` 全篇採用 `${var}` 形式。
同一個 bash 3.2 家族的坑還有：`$( )` 裡的 `case` 分支 `)` 會被誤判成命令替換結尾
（`bin/fleet` 開頭定位自身路徑那段因此改用 `${p#/}` 比對而不用 `case`）。

---

## 工作流

### 25. 「等價執行」一律當成沒做

**症狀**
派工要求 worker 跑一個特定的工作流（一個 skill、一個 script、一套檢查），
worker 回報「已等價執行」「用相同邏輯完成了」。
去查實際結果——**什麼都沒有**。曾經要求跑一套 review 流程，
worker 回「review 工作流等價執行」，實際 PR 上 **0 筆 review**。

**根因**
worker 傾向於「我理解了這個工作流要做什麼，所以我在腦內做了等價的事」。
但工作流的價值往往在**副作用**（留下 review 紀錄、更新票務狀態、觸發 CI），
不在它的思考內容。腦內執行不會產生副作用。

**修法**

- **在派工單裡把「等價執行不算」寫死。** 明確要求執行那個具體的東西。
- **驗收要查副作用的客觀證據**，不是查 worker 的說法：
  - 要求跑 review → 查該平台的 reviews API 回傳不是空陣列
  - 要求更新票 → 查票務系統上的狀態真的變了
  - 要求跑測試 → 要測試輸出原文，不要「應該會過」
- worker 回報裡出現「等價」「相當於」「相同效果」這類字眼，**當成紅旗**。

**對應機制**
`share/task-template.md` 的回報格式段；[commander-protocol.md](commander-protocol.md) 的驗收章節。

---

### 26. APPROVED ≠ 可合併

**症狀**
review 顯示 APPROVED，你以為可以合併了。實際上 CI 是紅的。

**根因**
review 與 CI 是**兩條獨立的檢查線**，通過其中一條不代表另一條。

實案：一個 PR 拿到 APPROVED，但 CI 因為 10 個純風格 lint issue 而紅。
更糟的是 **lint 擋在 Test / Build 前面**——lint 沒過，測試根本沒跑，
所以那個當下沒有任何人知道這份程式能不能編譯。

**修法**
合併前**兩個都要查**，而且要查實際狀態不是查 worker 的說法：

1. review 狀態（有沒有 approve、有沒有未解決的 comment）
2. CI 狀態（**每一個 job**，不是只看最上面那個聚合結果）

特別注意 CI pipeline 的**順序**：前面的 job 失敗會讓後面的 job 根本不執行，
這時「後面的 job 沒有紅」不等於「後面的 job 過了」。

**對應機制**
純工作流約定，不在程式碼裡。寫進 [commander-protocol.md](commander-protocol.md)。

---

### 27. 重試上限 2：連錯兩次就是方法錯了

**症狀**
同一個問題修了一輪又一輪，問題數字上上下下，就是收斂不了。

實案：一個 PR 跑了 **7 輪** review，嚴重問題數變化是
`3 → 2 → 2 → 1 → 1 → 2 → 3`——**最後一輪回升到起點**。
而且新冒出來的問題**全都是前兩輪修法自己造成的**。

**根因**
逐點補丁。每輪只針對 reviewer 點出的個別問題打補丁，
沒有回頭問「為什麼一直冒新問題」。真正的根因是**設計層面的**，
而補丁是在**症狀層面**打的——症狀被壓下去，根因換個地方冒出來。

**修法**

- **同一個方法最多試 2 輪。** 第 3 次動手前，必須：
  - 換方法（不同的解法路徑），或
  - 換人（換一個 worker、fresh context 重新看這個問題），或
  - 升級模型
- 第 3 輪之前強制回答一個問題：**「這些問題有沒有共同根因？」**
  如果每輪冒出來的新問題都跟上一輪的修法有關，那就是有。
- 收斂不了的時候，**revert 回乾淨狀態重做，通常比繼續補快**。

**對應機制**
純工作流約定。也是 watcher 熔斷機制（第 7 條）背後的同一個哲學：
**重試要有上限，無上限的重試只會放大錯誤。**

---

### 28. `capture-pane -S -N` 不是「最後 N 行」——狀態判定吃到 scrollback 會靜默卡死

**症狀**
所有通知都送不出去，但**沒有任何錯誤**：`fleet watch status` 說 watcher 運作中，
worker 也真的在交報告，指揮官就是一則都收不到。
唯一的線索藏在 `fleet watch log` 裡，而且只是 `debug` 等級：

```text
2026-08-03T02:09:41Z debug notify-idle-deferred  rc=2 worker=dianke
2026-08-03T02:09:46Z debug notify-idle-deferred  rc=2 worker=dianke
...連續 297 筆
```

`rc=2` 是「使用者正在打字，不插隊」。設計上它**不記帳、不熔斷**——
因為延後不是失敗。代價是：一旦這個判定卡在恆真，整套閉環就會**安靜地失效到天荒地老**。

**根因**
`tmux capture-pane -S -N` 的語意是「從**可見區頂端**往上 N 行開始，
一路抓到可見區底部」，**不是**「畫面最後 N 行」。
`-S -8` 在一個 51 行高的 pane 上實測回 **59 行**。

於是「看畫面末 8 行判斷輸入框有沒有字」實際上變成「看 scrollback + 整個畫面」。
而這台機器的 zsh 提示符正好是 `❯`，scrollback 裡任何一行歷史命令——

```text
❯ clear
❯ cc -c
```

——都永遠符合 composer 規則 `❯[[:space:]]+[^[:space:]]`。
輸入框明明是空的，判定卻恆真。

同一個錯誤在看板上的表現是另一種：閒置的 worker 一直顯示「跑中」，
因為 scrollback 裡有早就滾掉的 `esc to interrupt`。

**修法**

把「讀畫面」拆成語意明確的三個，不要讓呼叫端自己記 `-S` 的行為：

| 函式 | 抓什麼 | 用在哪 |
|---|---|---|
| `pane_capture` | 只有可見畫面 | **所有狀態判定**（忙碌／卡住／等答） |
| `pane_capture_tail` | 可見畫面「有內容的」最後 N 行 | composer（使用者在不在打字） |
| `pane_capture_history` | scrollback + 可見畫面 | **只有**送達驗證 |

兩個容易再踩的細節：

1. `pane_capture_tail` **不能只是 `tail -n N`**。畫面沒被填滿時底部是一堆空行，
   `tail` 會全部拿到空行，真正的 composer 行反而在上面被切掉。
   要先剝掉尾端空行再取。真 TUI 通常畫滿整屏所以平常看不出來——
   這種「大部分時候剛好會動」的東西最難查。
2. 送達驗證用 scrollback 是**安全的**，因為短單號（`r<mtime>`）是唯一的，
   抓到舊的也不可能誤判。反過來，狀態判定用 scrollback 一定會出事。

**對應機制**
`lib/tmuxio.sh` 的三個 `pane_capture*`；`libexec/fleet-mon` 的 `inspect()` 同步只讀可見畫面。

**這條同時是對測試的警告。**
修完之後有兩條測試變紅，而它們原本是**靠這個 bug 才通過的**：
「使用者正在打字時回 2」那條根本沒有真的打出提示符，
是靠 scrollback 裡的 shell 提示符命中的——它測的是假象。
綠燈不等於測對了東西；**改實作時變紅的測試，要先問它原本為什麼會綠**。
