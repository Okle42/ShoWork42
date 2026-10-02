# ShoWork42 for Windows（開發中）

對象：傳統主控台視窗（conhost）與 Windows Terminal ＋ Claude Code。功能目標與 macOS 版相同。

| 階段 | 內容 | 狀態 |
|---|---|---|
| W0 | 光暈跟隨主控台視窗（移動、縮放、疊放、最小化）；AI 程序 → 主控台視窗對應 | ✅ e2e 21/21 |
| W1 | Claude Code hooks → 紫／綠／紅；Windows Terminal；按鍵／點擊清除；系統匣圖示；開機啟動 | ✅（見 W1-結果.md） |
| W2 | 設定視窗（三種狀態同一頁）；六種光芒；動態島（系統匣）；全螢幕邊緣光 | ✅（見 W2W3-結果.md） |
| W3 | 自動排版（每台螢幕各自排，Ctrl+Alt+L） | ✅（Windows 預設關） |
| W4 | 打包單一 exe（ShoWork42.exe 內含 runtime／ShoWork42-small.exe），雙擊安裝、「設定 > 應用程式」解除安裝 | ✅（見 W2W3-結果.md 的 W4 一節） |

## 做法（對照 macOS 版）

- **找視窗**：`AttachConsole(AI 的 pid)` → `GetConsoleWindow()`，不用猜標題（在 `showork.exe console` 子行程裡做）。
  conhost 拿到的就是視窗本身；Windows Terminal 拿到 ConPTY 的 `PseudoConsoleWindow`，它的 **owner** 是目前裝著該分頁的 WT 視窗。
- **光暈**：點擊穿透、不搶焦點的 layered window；位置用 DWM 的 `EXTENDED_FRAME_BOUNDS`（`GetWindowRect` 含隱形邊框會偏幾 px）。
  預設**朝內**（設定頁「光暈方向」，`settings.json` 的 `general.direction`）：光暈剛好蓋住視窗可見範圍、放在目標**正上方**
  （插在原本目標上面那個視窗底下；目標是一般視窗最上層時用 `HWND_TOP`，永遠不設 topmost），從邊緣往內漸淡、中間完全透明；
  點目標時目標會先跳到光暈上面，前景／疊放事件在幾十 ms 內把光暈放回去。**朝外**＝原本的做法，`SetWindowPos(glow, target)` 放在目標正下方。
- **跟隨**：out-of-context WinEvent hooks（移動、前景切換、疊放、最小化、關閉），外加 250ms 看門狗；只在有光暈時才開。
- **省資源**：光環點陣圖只在視窗大小或狀態改變時重畫；呼吸只改圖層透明度，不重畫。
- **hook → agent**：`showork.exe emit` 經 named pipe `\.\pipe\ShoWork42-<SID>` 送一行 JSON；200 ms 內一定結束、永遠 exit 0。
- **清除**：有綠的時候才裝 low-level 鍵盤／滑鼠 hook；WT 多分頁時用唯讀的標題比對判斷哪個分頁在畫面上。

## 已知坑

1. 主控台視窗底下掛著看不見的輔助視窗（輸入法等），判斷「光暈在正下方」要跳過看不見的視窗。
2. 高 DPI：`DwmGetWindowAttribute` 永遠回傳實際像素，`GetWindowRect` 會依呼叫者的 DPI 感知被縮放；量測程式也要宣告 Per-Monitor V2。
3. Windows 11 預設把 PowerShell 開在 Windows Terminal；測試用 `conhost.exe powershell` 明確開傳統視窗。
4. SSH 工作階段看不到使用者桌面，要顯示視窗的測試必須用互動式排程工作跑。
5. WT 的每個分頁假視窗都回報 visible，看不出哪個分頁在前面（見 W1-結果.md 的標題比對）。
6. `wt.exe` 參數裡的 `;` 是子指令分隔，引號裡面也一樣；測試分頁用 `-File 腳本` 帶參數。
7. 殺掉 WT 分頁裡的 shell 不會關分頁（非 0 結束碼會留著）；測試分頁要自己正常結束。
8. Claude Code 在 Windows 用 Git Bash 跑 hook：路徑要加引號、用正斜線；Git Bash 還會把 `/exit` 這種參數轉成 `C:/Program Files/Git/exit`（`MSYS_NO_PATHCONV=1`）。
9. 權限提示與 AskUserQuestion 的 Notification 都晚約 6 秒到，紅色改接 PermissionRequest／PreToolUse。
10. Windows PowerShell 5.1 呼叫原生程式會吃掉參數裡的雙引號；含中文的 .ps1 要存成 UTF-8 with BOM。

## 建置、安裝與測試

```powershell
cd windows\ShoWork.Win
dotnet build -c Release                                  # 同時 build showork.exe，放在 ShoWorkAgent.exe 旁邊
bin\Release\net8.0-windows\ShoWorkAgent.exe --install    # 複製到 %LOCALAPPDATA%\ShoWork42\bin、合併 hooks、開機啟動、啟動 agent
bin\Release\net8.0-windows\ShoWorkAgent.exe --status
bin\Release\net8.0-windows\ShoWorkAgent.exe --uninstall  # 停 agent、移除 hooks（settings.json 回到原本位元組）、移除開機啟動

# W0：光暈跟隨（會開兩個測試視窗並自動移動它們；-Direction inward（預設）或 outward）
powershell -File ..\tests\w0_e2e.ps1 -Agent bin\Release\net8.0-windows\ShoWorkAgent.exe -Out w0_result.txt -Direction inward
# W2：六種款式（對齊、疊放、點擊穿透、切換前景、CPU、截圖）
powershell -File ..\tests\w2\w2_glow.ps1 -Agent bin\Release\net8.0-windows\ShoWorkAgent.exe -Work $env:TEMP\sw42-glow -Direction inward
# W1：真實 Claude Code（需先 --install；會開一個 conhost 和一個 WT 視窗各跑一個 Haiku）
dotnet build -c Release ..\tests\Sw42Probe
powershell -ExecutionPolicy Bypass -File ..\tests\w1_e2e.ps1
```

偵錯：環境變數 `SHOWORK_DEBUG=1` ⇒ `%LOCALAPPDATA%\ShoWork42\agent.log`；`SHOWORK_STATUS_FILE` ⇒ agent 狀態 JSON；
`SHOWORK_PIPE`／`SHOWORK_HOME` ⇒ 測試用的獨立 pipe 名稱與資料夾。設了 `SHOWORK_PIPE` 的測試 agent 不會排版，
除非同時給 `SHOWORK_ONLY_WIDS`（白名單；加 `SHOWORK_ARRANGE_ONLY_LISTED=1` 則只排名單裡的視窗）。
