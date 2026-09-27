# ShoWork42 for Windows（開發中）

對象：傳統 PowerShell／cmd 主控台視窗（conhost）＋ Claude Code。功能目標與 macOS 版相同。

| 階段 | 內容 | 狀態 |
|---|---|---|
| W0 | 光暈跟隨主控台視窗（移動、縮放、疊放、最小化）；AI 程序 → 主控台視窗對應 | ✅ e2e 21/21 |
| W1 | Claude Code hooks → 紫／綠／紅；按鍵／點擊清除；系統匣圖示 | |
| W2 | 設定視窗（三種狀態同一頁） | |
| W3 | 自動排版（每台螢幕各自排） | |
| W4 | 打包單一 exe | |

## 做法（對照 macOS 版）

- **找視窗**：`AttachConsole(AI 的 pid)` → `GetConsoleWindow()`，不用猜標題。
- **光暈**：點擊穿透、不搶焦點的 layered window，`SetWindowPos(glow, target)` 放在目標正下方；位置用 DWM 的 `EXTENDED_FRAME_BOUNDS`（`GetWindowRect` 含隱形邊框會偏幾 px）。
- **跟隨**：out-of-context WinEvent hooks（移動、前景切換、疊放、最小化、關閉），外加 250ms 看門狗。
- **省資源**：光環點陣圖只在視窗大小或狀態改變時重畫；呼吸只改圖層透明度，不重畫。

## 已知坑

1. 主控台視窗底下掛著看不見的輔助視窗（輸入法等），判斷「光暈在正下方」要跳過看不見的視窗。
2. 高 DPI：`DwmGetWindowAttribute` 永遠回傳實際像素，`GetWindowRect` 會依呼叫者的 DPI 感知被縮放；量測程式也要宣告 Per-Monitor V2。
3. Windows 11 預設把 PowerShell 開在 Windows Terminal；測試用 `conhost.exe powershell` 明確開傳統視窗。
4. SSH 工作階段看不到使用者桌面，要顯示視窗的測試必須用互動式排程工作跑。

## 建置與測試

```powershell
cd windows\ShoWork.Win
dotnet build -c Release
# 在使用者桌面執行（會開兩個測試視窗並自動移動它們）：
powershell -File ..\tests\w0_e2e.ps1 -Agent bin\Release\net8.0-windows\ShoWorkAgent.exe -Out w0_result.txt
```
