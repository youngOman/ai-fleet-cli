# tests/fixtures — worker 畫面快照

`tests/signals.bats` 用這些檔案餵 `lib/signals.sh`,驗證訊號判定。
**用檔案而不是內嵌字串**的理由:訊號規則的真值來源是「worker 畫面長什麼樣」,
那是外部事實,不是測試碼的一部分。真的畫面變了,換這裡的檔案就好,不用改測試邏輯。

## 命名

`<kind>-<狀態>.txt`,`<kind>` 必須對得上 `adapters/<kind>.conf` 的檔名。
`tests/signals.bats` 會斷言 `detect_kind` 對每個檔案回傳檔名前綴那個 kind。

## 來源標示

每個檔案第一行是註解,標明是**真實錄製**還是**手工構造**:

* `# 來源:真實錄製` — 從活著的 worker pane `tmux capture-pane -p` 錄下來後逐行脫敏。
  只保留結構性外殼(狀態列、spinner 行、框線、`esc to interrupt`、`◔ NN%`…),
  所有專案內容、路徑、分支名、issue 編號、金額一律改寫成中性佔位字串。
* `# 來源:手工構造` — 錄製當下環境裡沒有這個狀態(例如剛好沒有卡住的 worker)。
  依 `adapters/*.conf` 的 regex 與同 kind 的真實錄製外殼手工組出來。

第一行註解**不會**被測試當成畫面內容以外的東西處理——`signals.sh` 只做 regex 比對,
多一行註解不影響判定,而且註解本身刻意不含任何訊號字串。

## 清單

| 檔案 | 行數 | 來源 | 代表的狀態 |
|---|---:|---|---|
| `cc-busy.txt` | 32 | 真實錄製 | 正在跑工具(計時器 + token 計數) |
| `cc-idle.txt` | 22 | 真實錄製 | 答完停下來,輸入框是空的 |
| `cc-composer-busy.txt` | 22 | 真實錄製 | 使用者正在輸入框打字 → 不可注入 |
| `cc-stuck-queued.txt` | 26 | 手工構造 | 排隊訊息 + 同時在忙 → **不是**卡住 |
| `cc-stuck-idle.txt` | 16 | 手工構造 | 排隊訊息 + 不忙 → 真卡住 |
| `cc-asking.txt` | 16 | 手工構造 | 停在互動選單等人回答 |
| `cc-verbs-no-structure.txt` | 24 | 手工構造 | 回歸:只有 spinner 動詞 → 不可判 busy |
| `cc-structure-no-verb.txt` | 14 | 手工構造 | 回歸:只有結構性訊號 → 必須判 busy |
| `cx-busy.txt` | 20 | 手工構造 | codex 正在跑(大寫的中斷提示) |
| `cx-idle.txt` | 28 | 真實錄製 | codex 交完報告停下來 |
| `cx-stuck-pasted.txt` | 19 | 手工構造 | 長訊息卡在輸入框不執行 |
| `cx-autoreply-faster-model.txt` | 19 | 手工構造 | 降級到快模型的攔截框 |

手工構造的四種 cc 狀態與三種 cx 狀態,是因為錄製當下環境裡沒有處於那些狀態的
worker(所有 worker 都在忙或已收工,沒有卡住的、沒有停在選單的)。
每一份都是照 `adapters/*.conf` 的 regex 加上**同 kind 的真實錄製外殼**組出來的,
不是憑空想像的畫面。

## 註解區必須是惰性的

fixture 的 `#` 註解會**連同內容一起**被餵給 `grep`——`lib/signals.sh` 不做任何
預處理。所以註解裡不可以出現訊號字串原文,否則 fixture 會靠自己的註解「自證」,
回歸測試就假綠了(這在建立測試時真的發生過:`cc-verbs-no-structure.txt` 的註解
寫了中斷提示的英文原文,結果它被判成 busy)。

`tests/signals.bats` 有一條 `fixture 的註解區必須是惰性的` 專門把關這件事。
要在註解裡提到某個訊號,用中文描述它,不要寫英文原文。

## 脫敏規則(新增 fixture 時照做)

1. 刪掉所有專案名、檔案路徑、程式碼片段、issue / PR 編號、人名、主機名、金額。
2. 只留結構性訊號本身。
3. 不可出現 `/Users/<名字>`、公司網域、內網 IP。
4. 錄完跑 `python3 scripts/scan.py tests/fixtures/` 確認乾淨。
