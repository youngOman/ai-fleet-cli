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

## 脫敏規則(新增 fixture 時照做)

1. 刪掉所有專案名、檔案路徑、程式碼片段、issue / PR 編號、人名、主機名、金額。
2. 只留結構性訊號本身。
3. 不可出現 `/Users/<名字>`、公司網域、內網 IP。
4. 錄完跑 `python3 scripts/scan.py tests/fixtures/` 確認乾淨。
