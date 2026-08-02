# 變更紀錄

本檔格式依循 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)，
版本編號依循 [語意化版本](https://semver.org/lang/zh-TW/)。

## [0.1.0] - 2026-08-03

首次公開釋出。把原本只能在自己機器上跑的個人腳本，整理成任何人都能安裝、
設定、測試的 CLI 工具。

### 新增

- **可安裝**：`install.sh` 安裝器與固定的目錄佈局（`bin/` / `lib/` /
  `libexec/` / `adapters/` / `share/`），`bin/fleet` 是唯一使用者入口。
  刻意不自動改寫使用者的 shell rc，只印出可複製的指令。
- **多 profile**：以 `FLEET_PROFILE` 切換不同艦隊，執行期資料收斂到
  `$FLEET_HOME/profiles/<profile>/`，同一台機器可以同時養多支艦隊互不干擾。
- **`fleet doctor`**：環境自我診斷，檢查 tmux、python3、路徑解析結果與
  設定檔來源，把「為什麼在我機器上不會動」變成一行指令就能回答。
- **`fleet lint`**：報告四節 schema 驗證，交上來的報告不合格當場擋下。
- **測試**：python3 `unittest` 覆蓋純函式邏輯（狀態機、去重、報告解析），
  bats 覆蓋 shell 層；tmux 互動部分以錄下來的畫面 fixture 驗證。
- **release gate**：`scripts/scan.py` 在 CI 擋下個人絕對路徑、硬編憑證、
  內網位址與私鑰區塊，避免個人資料隨著公開 repo 外流。
- **版本一致性檢查**：`scripts/check-version.sh` 比對 `bin/fleet` 的
  `FLEET_VERSION` 與 CHANGELOG 最新版本號。
- **shell 補全**：`completion/fleet.zsh` 與 `completion/fleet.bash`，
  worker id 直接從 registry 動態讀取，不硬編任何預設值。
- **CI**：GitHub Actions 在 ubuntu 與 macOS 上跑 shellcheck、單元測試與
  release gate。

### 變更

- **狀態集中到單一 `state.json`**：淘汰散落各處的 `.notified` / `.hash`
  旗標檔，去重、熔斷、worker 轉換全部由 `libexec/fleet-state` 一個人寫入，
  且採 temp + rename 原子寫。
- **adapter 資料化**：worker CLI 的偵測 / 就緒 / 忙碌 / 卡住 regex 從程式碼
  抽成 `adapters/<kind>.conf` 純資料檔。新增一種 worker CLI 只要多一個
  `.conf`，不必改任何一行程式碼。
- **報告 worker 解析改為對照 registry**：只接受能對上 registry 的 id
  （取最長匹配），對不上就留白，不再用切字串的方式猜出根本不存在的 worker。
- **送訊一律回讀驗證**：`send_verified` 明確區分「送達 / 驗不到 / 使用者正在
  打字 / TUI 沒起來」四種結果，只有真的驗不到才記 attempt。

### 修正

- **UTF-8 報告檔名造成的 state key 碰撞**：舊版把檔名逐 byte 轉碼成
  `A-Za-z0-9_.-`，中文主題會整段被壓成一串底線，同一天同一個 worker 的兩份
  中文報告因此撞 key，後交的那份被永久靜音。現在 key 直接使用檔名原文。
- **通知只走預設 tmux socket**：舊版通知指揮官時用的是裸 `tmux`，指揮官若不在
  預設 socket 上就會全部靜默失敗。現在所有 tmux 呼叫一律帶 socket。
- **忙碌判定 regex 漂移**：同一組訊號比對規則曾被複製到四個檔案並各自演化，
  導致看板顯示忙碌但 watcher 認為閒置。現在統一由 `lib/signals.sh` 從
  adapter 設定檔讀取，全系統只有一份。

[0.1.0]: https://github.com/youngOman/ai-fleet-cli/releases/tag/v0.1.0
