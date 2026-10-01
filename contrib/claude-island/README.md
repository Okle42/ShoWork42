# Claude Island（動態島＋螢光條）

在另一台 Mac 上（macOS 13.7、Terminal.app）做的 Claude Code 狀態提示，**概念改編自 ShoWork42**，寫成單一 Swift 檔案，放在這裡給 Kang 參考。
這個資料夾是獨立的，**沒有改動 ShoWork42 本身的任何程式碼**，也沒有接進 `Package.swift`。

## 長什麼樣子

### 右上角的動態島（每個 Claude 對話一顆）
位置在選單列時間正下方，也就是系統通知出現的地方。新的疊在最上面，名稱用分頁標題裡的對話主題。

| 狀態 | 膠囊 |
|---|---|
| 處理中 | 細長小膠囊：橘色 Claude 光芒旋轉＋呼吸、名稱有流光掃過、計時、跳動的聲波條 |
| 需要授權／提問 | 膠囊變大，橘色鈴鐺搖晃，寫「需要你授權」或「在問你問題」 |
| 完成 | 綠色圓圈畫出勾＋外擴漣漪，寫「完成了 · 用時 N 秒」；8 秒後縮成小顆「✓ 名稱 完成」，**一直留到你看過** |

- 狀態切換是同一顆膠囊變形（Apple 彈簧動畫＋模糊淡入淡出），出現時從右邊滑入。
- 點膠囊：跳到那個視窗、選到那個分頁（完成的會順便清掉）。

### 終端機視窗的螢光條
- 細的外暈（約 6pt）＋視窗**內側**一圈 1.8pt 燈條（旁邊被別的視窗蓋住時也看得到）。
- 處理中：橘、粉、紫漸層慢慢繞著轉並呼吸；需要授權：琥珀色快閃；完成：綠色，閃一下後一直亮著。
- 用 Core Animation 做（模糊光圈只在視窗大小改變時畫一次，旋轉和呼吸交給 GPU），滑鼠可以穿透。

### 選單列總覽
選單列顯示 `●1 ●2 ●1`（各狀態數量），點開列出每個對話，點一下直接跳過去；有「清除所有完成了」。

## 從 ShoWork42 借來的概念
1. **tty 精準對到視窗**：hook 往上找父程序的 tty，Terminal／iTerm2 用 AppleScript 問哪個視窗（視窗 id＝CGWindowID）。
   Ghostty 照 ShoWork42 的 OSC 7 記號法：往 tty 寫一次性記號 → AppleScript 找 `working directory` 含記號的 terminal → 用視窗名稱比對 CGWindowList（同名時暫時用 OSC 2 標題記號分辨）→ 還原工作資料夾與標題。
2. **內側燈條**：重疊排列時外暈被蓋住，內光還在。
3. **完成要看過才清**：切到該視窗、在裡面點擊、點膠囊、或送出新訊息才清除。
4. **同一個視窗多個分頁取最緊急**：授權 > 完成 > 處理中。
5. **選單列 ● 數量＋點選跳轉**。
6. **Notification 只接 `permission_prompt|elicitation_dialog`**，60 秒閒置提醒不會誤判成「等你」。
7. **視窗貼齊選單列時不被系統往下推**（覆寫 `constrainFrameRect`）。

## 和 ShoWork42 的差別
- 單一檔案、沒有常駐程式：第一個 hook 叫起背景程序，所有膠囊都清掉後自己結束；用 DistributedNotification 傳狀態，不用 socket。
- 不需要輔助使用權限：看過與否用「視窗切到最前面」＋全域滑鼠點擊判斷（滑鼠監聽不需權限）。只需要第一次允許控制 Terminal（AppleScript）。
- Claude 程序結束（`kill -0` 失敗）自動清除。
- 顏色用 Apple 系統色（處理中 Claude 橘、授權 #FF9F0A、完成 #30D158）。

## 測過／沒測過
- ✅ macOS 13.7.8、Terminal.app、同時 6 個 Claude 分頁：對到視窗、三種狀態、看過清除、程序結束清除、選單列。
- ✅ CPU：有處理中膠囊時約 12%（SwiftUI 小動畫 30fps），只剩完成時約 1%，全部清掉後程式結束。
- ⚠️ iTerm2 的 AppleScript 有寫但沒實測。
- ✅ Ghostty 1.3.1（macOS 13.7）：OSC 7 記號對應。開兩個 Ghostty 視窗、把另一個放最前面，仍對到跑 Claude 的那個；工作資料夾有還原。點膠囊用 `focus terminal id` 跳過去。
- ⚠️ Ghostty 讀視窗名稱需要「螢幕錄製」權限（第一次會跳詢問，權限算在 Ghostty 上）；沒給的話退回「送出訊息當下最前面的 Ghostty 視窗」。沒用 AXDocument，所以不需要輔助使用權限。
- ⚠️ Ghostty 背景分頁（不是選中的分頁）而且多個視窗同名時，OSC 2 分辨法看不到，會退回最前面視窗。
- ❌ 全螢幕、跨桌面、tmux 都沒處理。

## 試用

```bash
cd contrib/claude-island
./demo.sh          # 編譯＋跑一次示範動畫，看螢幕右上角
```

接到 Claude Code（`~/.claude/settings.json` 的 hooks，路徑換成自己的）：

```json
{
  "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "/path/to/claude-island run",  "async": true }] }],
  "PostToolUse":      [{ "hooks": [{ "type": "command", "command": "/path/to/claude-island tick", "async": true }] }],
  "Stop":             [{ "hooks": [{ "type": "command", "command": "/path/to/claude-island done", "async": true }] }],
  "Notification":     [{ "matcher": "permission_prompt|elicitation_dialog",
                         "hooks": [{ "type": "command", "command": "/path/to/claude-island wait", "async": true }] }],
  "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "/path/to/claude-island hide", "async": true }] }]
}
```

清除的原因會寫在 `~/.claude/island/island.log`。
