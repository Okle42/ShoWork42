# 戰情中心自己持有 session（脫離終端機）

目標：使用者在戰情中心裡就能完成所有工作，不必切到終端機。
架構（11-08 使用者拍板「A＋交棒」）：

- **平常**：戰情中心直接持有 session。用 Claude Code 官方串流模式
  `claude -p --input-format stream-json --output-format stream-json --verbose`，stdin 一直開著，
  一個 session 一個長駐程序。對話、工具過程、權限、中斷都是第一手資料。
- **交棒**：同一個 session 可以在戰情中心和終端機之間換手（兩邊共用同一份對話紀錄，`--resume <id>`）。
  - 「在終端機打開」：戰情中心先關掉自己的程序，再開終端機跑 `claude --resume <id>`。
  - 「搬進戰情中心」：終端機那邊結束後，戰情中心用 `--resume <id>` 接回（舊 session 也能這樣搬進來）。
  - 同一個 session 同一時間只能有一邊在跑（鎖）。

## Step 0 實測（11-08，haiku，背景 tmux、不開視窗）

| 項目 | 結果 |
|---|---|
| 長駐程序連續多回合 | ✅ 記得前一回合 |
| 中斷：stdin 送 `{"type":"control_request","request_id":…,"request":{"subtype":"interrupt"}}` | ✅ 回 `control_response` success；該回合 `result` 是 `error_during_execution`；程序還活著，下一回合正常 |
| 權限：`--permission-mode default` 下用 Write | ✅ `PermissionRequest` hook 照常被呼叫（`tool_name: Write`），回 allow 後檔案寫成 ⇒ 現有 `showork permit` 收件匣流程不用改 |
| 交棒到終端機：`claude --resume <id>` 互動模式 | ✅ 畫面上有之前的對話，問暗號答對 |
| 終端機放手後再接回串流模式 | ✅ 記得終端機裡最後一句，session id 不變 |

## 分階段

| 階段 | 內容 | 驗收 |
|---|---|---|
| H1 | `SessionHost`（ShoWorkCore）：開／接回／送訊息／中斷／關閉；事件寫進 `board/sessions/<sid>.jsonl`；擁有者紀錄（board／terminal）＋鎖 | 單元測試用假 claude（不准真的呼叫）；e2e 用 haiku 一次 |
| H2 | 交棒：在終端機打開（Ghostty 開新視窗跑 `claude --resume`）／搬進戰情中心（偵測終端機那邊結束） | 實測兩個方向各 3 次 |
| H3 | 工作視窗（網頁，Mac WKWebView／Windows WebView2 共用）：對話流、工具呼叫摺疊、diff、輸入框（多行、拖檔、貼圖）、中斷、模型、`/compact` 等指令、權限卡內嵌 | 真瀏覽器截圖驗 |
| H4 | 「新任務」「交給隊長」改走 SessionHost（取代 `claude --bg`） | 從戰情中心開一個任務做到完成，全程不碰終端機 |
| H5 | 3D 辦公室改版（大樓換成單層開放辦公室，three.js 兩平台共用；城市、B1 保留）：點角色＝打開它的工作視窗 | |

## 注意

- 不要用 `ghostty -e` 開終端機：會啟動第二份 Ghostty 並還原上次的視窗（見 ARCHITECTURE.md 已知坑）。
- 戰情中心持有的程序要跟著戰情中心（agent）的生命週期：agent 重啟時，用 `--resume` 接回原本開著的 session。

## 進度（11-08）

- ✅ H1 `Sources/ShoWorkCore/SessionHost.swift`：測試 `SessionHostTests`（假 claude）＋`SessionHostE2E`（`SHOWORK_E2E_CLAUDE=1`，真 haiku）。
  看板 `Board.build(owned:)` 放行戰情中心持有的 `sdk-cli` session，卡片 `kind == "board"`。
- ✅ H2 `Sources/ShoWorkAgent/OwnedActions.swift`：送話時 `SessionHost.ensure` 自動接回；在終端機打開＝Ghostty AppleScript
  `new surface configuration`（`initial working directory`、`initial input`）＋`new window with configuration`。
  腳本語法與屬性已用 osascript 驗過（沒開視窗）；**真的開 Ghostty 視窗交棒還沒實測**（會開在使用者螢幕上，要先問）。
- ✅ H3 工作視窗（Mac）：網頁 `windows/ShoWork.Win/Board/Web/work.{html,css,js}`（示範 `work.html?demo=1`），
  Mac `Sources/ShoWorkAgent/WorkWindow.swift`；訊息格式在 Web/PROTOCOL.md「工作視窗」。
  - 對話來源讀 log（打開時重播、之後照 offset 每 0.3 秒讀新行），不掛 `OwnedSession.onEvent`：ensure 換程序也接得上。
  - work.js 用一般 script，file:// 就能載入，沒用自訂 scheme（跟原規格不同，原因同上一行：不需要 ES module）。
  - 入口：新任務改開 SessionHost session 並打開工作視窗（不再用 `claude --bg`）；點 `kind == "board"` 的角色＝打開工作視窗；
    右鍵：board 角色「打開工作視窗」，其他角色多「搬進戰情中心」。
  - 安裝腳本把 work.{html,css,js} 放進 ShoWorkAgent.app 的 Resources/Web。
  - 驗證：瀏覽器截圖（示範資料）；`ShoWorkAgent --work-snap <資料夾> <sid> <png>` 在螢幕外開真的 WKWebView 截圖，
    重播、即時新增行、送話（`SHOWORK_CLAUDE_BIN` 假 claude：送出→自動接回→回覆出現）、換權限模式都跑過。
  - 還沒做：Windows 端的 WebView2 宿主；`/compact`、`/clear` 在串流模式的行為還沒用真 claude 實測（目前當一般文字送）；
    權限卡只用示範資料驗過畫面，沒接真的 PermissionRequest 跑一次；真的開 Ghostty 交棒仍未實測（要先問使用者）。

## H3 規格（下一棒照這個做）

- 網頁 `work.html`（跟 3D 辦公室同一個 Web 資料夾，Mac WKWebView／Windows WebView2 共用）；Mac 端 `WorkWindow.swift` 用 WKWebView，
  自訂 scheme 載入（file:// 下 ES module 會被擋）。
- Swift → 網頁：打開時先重播 `board/sessions/<sid>.jsonl`，之後 `OwnedSession.onEvent` 每行即時推。
- 網頁 → Swift：`send {text, images[]}`、`interrupt`、`openInTerminal`、`close`、`setModel`（control_request `set_model`）、
  `setPermissionMode`（`set_permission_mode`）、`permit`（沿用現有 `BoardActions.permit`，權限卡內嵌在對話流裡）。
- 畫面：對話流（使用者／AI 文字、工具呼叫一行摘要可展開、Edit/Write 顯示 diff、錯誤紅字）、底部多行輸入框（⌘↩ 送出、拖檔、貼圖）、
  上方：專案／模型／權限模式／ctx 用量、「中斷」「在終端機打開」「關掉」。
- 斜線指令：先做 `/compact`、`/clear`（送字串，串流模式下會照常處理的先實測）、`/model`（改走 set_model）。
- 入口：戰情中心「新任務」改成開 SessionHost session 並打開工作視窗；點 kind == "board" 的卡片＝打開工作視窗；
  非 board 的卡片多一個「搬進戰情中心」。
