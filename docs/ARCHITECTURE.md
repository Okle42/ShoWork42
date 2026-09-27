# ShoWork42 架構

## 總覽

```
 AI 工具（Claude Code hooks／其他 adapter）
        │  showork emit <working|done|input|clear> --agent claude
        ▼
 showork（CLI，Sources/showork）
        │  往上找父行程拿到 AI 所在的 tty；一行 JSON（WireMessage）
        │  Unix socket：~/Library/Application Support/ShoWork42/agent.sock（0600）
        │  非阻塞連線，200 ms 放棄，永遠 exit 0
        ▼
 ShoWorkAgent（LaunchAgent 常駐，無 Dock 圖示，Sources/ShoWorkAgent）
   ├─ Server         socket 收訊 → 丟到主執行緒
   ├─ Engine         每個 tty 一個 Tab 狀態；每個視窗取最高優先序；持久化 state.json
   │    ├─ Resolver      tty → 畫面上的 Placement（終端機 App、pid、CGWindowID、分頁 tty）
   │    ├─ Glow          每個視窗一個點擊穿透的光暈視窗，疊在目標正下方；全螢幕改 EdgeGlow
   │    ├─ ClearWatcher  前景視窗裡按鍵／點擊 ⇒ acknowledge（綠清除）
   │    └─ reaper        每 5 秒清掉已結束的 AI 行程
   ├─ TitleWatcher   後備：每 2 秒一次 AppleScript 讀 Ghostty 全部分頁標題
   ├─ Arranger       終端機視窗自動排版，每台螢幕各自排（幾何在 ShoWorkCore/LayoutPlan）
   ├─ Menu           選單列 ●數量＋清單跳轉
   └─ SettingsPanel  分頁式設定視窗（GlowSettings 存 UserDefaults，改了即時套用）

 ShoWorkCore（純邏輯、無 UI，可單元測試）
   WorkState/StateMachine · WireMessage/TTYFinder/Paths · LayoutPlan · TitleSignal
```

## Target 與檔案

| Target | 檔案 | 職責 |
|---|---|---|
| **ShoWorkCore** | `WorkState.swift` | 狀態 idle/working/done/input、事件、轉換規則、多分頁取優先序 |
| | `Wire.swift` | socket 訊息格式（v1，只接受 `/dev/tty*`）、路徑、`TTYFinder` |
| | `LayoutPlan.swift` | 1–11+ 個視窗的排版幾何（純計算，不碰視窗） |
| | `TitleSignal.swift` | Claude 標題 → 忙碌／閒置訊號（◐◑◒◓ 忙、✳ 閒、`N working`／`N awaiting input`） |
| **showork** | `main.swift` | hook 呼叫的極小 CLI |
| **ShoWorkAgent** | `main.swift` | 進入點、輔助使用權限等待＋re-exec、除錯子指令 |
| | `Server.swift` | Unix socket listener |
| | `Engine.swift` | 狀態中樞、光暈生命週期、看門狗、持久化 |
| | `Resolver.swift` | tty → 視窗對應（見下） |
| | `ProcTree.swift` | 行程樹、tty 前景行程、tmux socket 查詢 |
| | `Selection.swift` | 「使用者正在看這個分頁嗎」 |
| | `Glow.swift` | GlowView（六種款式）＋光暈視窗＋EdgeGlow |
| | `GlowSettings.swift` | 每種狀態的外觀設定、舊存檔遷移 |
| | `SettingsPanel.swift` | 設定視窗 |
| | `TitleWatcher.swift` | 標題後備偵測 |
| | `Arranger.swift` | 排版執行（每台螢幕獨立一組）、疊放整理（只動你所在的螢幕）、⌃⌥L、測試白名單 |
| **scripts** | `showork_install.py` | 編譯、簽章、LaunchAgent、合併／移除 Claude hooks |
| **adapters** | `claude/hooks.py` | 產生 Claude hooks 片段 |

## 狀態機

| 事件 | 來源（Claude） | 結果 |
|---|---|---|
| `working` | UserPromptSubmit、PreToolUse（`AskUserQuestion` 以外）、PostToolUse | 紫 |
| `done` | Stop | 綠，直到該視窗內按鍵／點擊（視窗在前景也一樣） |
| `input` | PreToolUse `AskUserQuestion`；Notification（`permission_prompt`、`elicitation_dialog`） | 紅，直到 AI 發下一個事件 |

`AskUserQuestion` 的問題在 PreToolUse 當下就出現，Claude 的 `elicitation_dialog` Notification 要晚約 6 秒才到（09-28 agent.log 實測），所以紅色改在 PreToolUse 送。同一事件的 hook 是並行跑的，catch-all 用 matcher `^(?!AskUserQuestion$)` 排除它，免得並行的 `working` 比 `input` 晚到把紅蓋掉。舊版安裝重跑 `install` 會自動把自己的舊 hook 群組換成新的。
| `clear` | SessionEnd | 無 |

刻意**不**對應 60 秒閒置提醒，否則已完成的綠會被改成紅。

## tty → 視窗對應（Resolver）

| 終端機 | 方法 |
|---|---|
| Terminal.app／iTerm2 | AppleScript 的 window id 就是 CGWindowID；分頁用 tty 比對 |
| Ghostty | 對分頁 tty 寫 OSC 7 探針 `file://<host>/tmp/SW42-<nonce>`，AppleScript 讀 terminal `working directory` 找到分頁→視窗；AX 視窗的 `AXDocument` = 選中分頁的 cwd，用來對到 AX／CGWindowID；最後寫回原 cwd。不動標題 |
| tmux | pane tty → 所屬 session → 每個 client tty → 再走上面的方法（detached ⇒ 不發光） |

AX 視窗 → CGWindowID 用私有 `_AXUIElementGetWindow`。

## 已知坑（實測）

1. OSC 7 主機名要用 `gethostname`；`ProcessInfo.hostName` 會轉小寫，Ghostty 會忽略。
2. macOS 27 讀不到其他行程的環境變數（`KERN_PROCARGS2` 只剩 28 bytes），所以不靠 `TMUX` 變數，改走行程樹。
3. Ghostty 分頁的行程樹會經過 root 身分的 `login`，列舉要用 `KERN_PROC_ALL`。
4. Ghostty AppleScript：`tab` 是類別名稱，用 `character id 9`；關視窗要寫 `close window (first window whose id is X)`。
5. iTerm2 只在 key window 更新標題，測試時先 AXRaise 再讀。
6. 光暈視窗會被選單列往下推，要覆寫 `constrainFrameRect`。
7. 切換 App 後疊放順序會晚一拍：分段重排（0.05／0.25／0.6 秒）＋單一 0.5 秒看門狗。
8. `NSGlassEffectView` 在非 .app 的 agent 不會繪製，設定視窗改用 `NSVisualEffectView`。
9. `ghostty -e …` 會啟動第二份 Ghostty；這時 `application id` 會對到新的那份（待修：改以 pid 對應）。

## 多螢幕與螢幕尺寸

- 每個視窗歸屬「中心點所在的螢幕」，每台螢幕各自套用 1–11 個視窗的排法。
- 重疊排法的兩個常數（每排露出 300pt、砌磚每排 120pt）以 1080p 級螢幕（可用高度 ≤ 1000pt）為準；更高的螢幕按高度比例放大，更小的螢幕維持原值（保證每個視窗有自己的露出帶）。單元測試涵蓋 13"／14" MacBook、1440p、5K、外接 1080p。
- 光暈座標一律以主螢幕左上為原點換算，跨螢幕不需特別處理；全螢幕邊緣細光畫在該全螢幕視窗所在的螢幕。

## 資料位置

`~/Library/Application Support/ShoWork42/`

| 檔案 | 用途 |
|---|---|
| `agent.sock` | CLI ↔ agent |
| `state.json` | 各 tty 狀態，agent 重啟後還原 |
| `agent.log` | `SHOWORK_DEBUG=1` 時的事件紀錄 |
| `bin/` | 安裝後的 `showork`、`ShoWorkAgent` |
| `backup/` | 寫入 `settings.json`、偏好前的備份 |

LaunchAgent：`~/Library/LaunchAgents/ai.okle42.showork.agent.plist`

## 環境變數

| 變數 | 用途 |
|---|---|
| `SHOWORK_SOCKET` | 改 socket 路徑（測試用） |
| `SHOWORK_DEBUG` | 開 agent.log |
| `SHOWORK_ONLY_WIDS` | 排版測試白名單；名單外視窗在畫面上就拒絕動作 |
| `SHOWORK_ARRANGE_NOOP` | 排版只檢查不搬 |
| `SHOWORK_STATUS_FILE` | e2e 讀取狀態輸出 |
