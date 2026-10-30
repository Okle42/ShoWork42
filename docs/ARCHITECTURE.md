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
   │    ├─ ClearWatcher  前景視窗裡按鍵 ⇒ acknowledge（綠清除；點擊不清）
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
| `done` | Stop | 綠，直到你在該視窗打字（只看、點擊都不清；10-09 曾改成等下一則指令，10-20 Kang 改回打字就清） |
| `done`＋自報 blocked | Stop，且這一輪（最後一個 `working` 起算）的 `showork card` 是 `--status blocked` | 橘（`waiting`），等外部的事；清除規則同綠 |
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
10. 光暈視窗的 `collectionBehavior` 要用 `.transient`，不能用 `.managed`。用 `.managed` 時，指揮中心（Mission Control）會把光暈當成一般視窗另外排版，畫面上出現一排跟目標視窗分開的空框。`.transient` 跟「固定在哪個桌面」是兩組獨立的設定，改了不影響後者。代價是指揮中心裡不顯示顏色框，這點無解，因為我們的視窗沒辦法黏在別的 App 的視窗上。另外，一般左右切換桌面時框會錯開 0.1～0.5 秒，這是動畫過程，不是 bug。
11. 在 `app.run()` 之前建立或關閉的 NSWindow 永遠不會被釋放，因為那時主執行緒還沒有 autorelease pool。啟動時的 `restore()` 因此每次會留下約 7 個 ordered-out 的死框（10-07）。解法是把會建立視窗的初始化工作延到主迴圈開始之後（`DispatchQueue.main.async`）。
    - 檢查方法：用 `CGWindowListCopyWindowInfo(.optionAll)` 數 ShoWorkAgent 的視窗，看不在畫面上（off）的有幾個；或用 `heap <pid> | grep GlowWindow` 看 GlowWindow 的數量，正常應該是 Glow 數量的 2 倍。
    - agent 有 hardened runtime，`leaks --traceTree` 追不到參照鏈。要找原因，就把 `Sources` 複製出來另外編一個測試程式重現，逐項比對差異（這次就是比出「建立時間點在 run loop 之前」）。

## 多螢幕與螢幕尺寸

- 每個視窗歸屬「中心點所在的螢幕」，每台螢幕各自套用 1–11 個視窗的排法。
- 重疊排法的兩個常數（每排露出 300pt、砌磚每排 120pt）以 1080p 級螢幕（可用高度 ≤ 1000pt）為準；更高的螢幕按高度比例放大，更小的螢幕維持原值（保證每個視窗有自己的露出帶）。單元測試涵蓋 13"／14" MacBook、1440p、5K、外接 1080p。
- 光暈座標一律以主螢幕左上為原點換算，跨螢幕不需特別處理；全螢幕邊緣細光畫在該全螢幕視窗所在的螢幕。

## 戰情中心（Board，P1 唯讀，10-08）

選單「戰情中心⋯」打開五欄看板：待辦／進行中／待審／完成／卡住，每個開著的 Claude Code session 一張卡。

| 來源 | 拿什麼 |
|---|---|
| `~/.claude/sessions/<pid>.json` | 開著的 session、`status`（busy／idle／shell）。行程已結束的殘留檔略過 |
| `~/.claude/projects/<slug>/<sid>.jsonl` 尾端 512 KB | `ai-title`、最後 cwd（往上找 `.git` 當專案名）、最後一句 AI 的話、排隊中的訊息（`queue-operation`）。slug＝啟動 cwd 裡英數字以外全換成 `-`（中文也是） |
| ShoWork 自己的 `state.json` | 光暈狀態：紅＝等你回答、綠＝做完你還沒看（比 status 檔即時） |
| `~/.claude/teams/<隊>/config.json`、`inboxes/*.json` | agent team 隊員與訊息（session 一關資料夾就被刪、信箱讀過就清空） |

分欄（`Board.column`，ShoWorkCore 有單元測試）：紅 → 待審；橘 → 卡住；busy 或紫 → 進行中，超過 10 分鐘沒新紀錄 → 卡住；綠 → 待審；其餘（含 `shell`＝這輪做完但背景指令還在跑）→ 完成；排隊中的訊息各一張待辦卡。

- 隊員進出、隊員訊息、換欄都追加到 `~/Library/Application Support/ShoWork42/board/history.jsonl`，重開時讀回來，隊伍解散後卡片上還看得到隊員與訊息。
- 全程唯讀，不寫 `~/.claude` 任何東西。每 1.5 秒讀一次，對話紀錄只在檔案變了才重讀。
- 測試入口：`ShoWorkAgent --board-dump`（印 JSON）、`--board-window`（只開看板，不開 socket；`SHOWORK_APPEARANCE=dark` 截深色）。不認得的 `--參數` 一律 exit 2（10-08：舊版不認得新參數，多開一個 agent 把正式 agent 的 socket 搶走）。
- 3D 辦公室（10-20，`OfficeView.swift`，SceneKit）：工具列左上切換 3D 辦公室／部門島（`board.mode`，預設 office；舊的 `board.view` 存過 islands 所以換新鍵）。一個專案一間辦公區、一個 session 一張桌＋Kubo，後牆浮霓虹看板（📈🎯🧠＋一句回報，只繞 Y 軸轉向鏡頭）。結構變才重建，狀態變只換那張桌／那面看板。點角色＝跳視窗（拖曳超過 4pt 不算點）、右鍵＝部門島同一組動作、WASD/方向鍵走動、Q/E 升降。省電：12 fps、2x 反鋸齒、不開陰影、視窗被蓋住就停（10-20 實測 30 fps＋陰影 CPU 30–75% → 4–7%）。你沒動過視角時視窗改大小會自動重新取景。測試：`SHOWORK_OFFICE_PROBE=1 … --board-window` 把每個角色投影回畫面、走點擊同一條 hitTest，印 OK／MISS；`SHOWORK_OFFICE_FPS` 調幀率。
- 3D 辦公室第二版（10-20 workflow office3d-upgrade）：BoardCard 加 `activity`（讀檔／改檔／跑指令／搜尋／思考／交辦）、`blockedReason`（🔒權限 ⏳額度 ⚠️API 🧪測試 🔨建置 📦安裝）、`subagents`（同步＋背景 Agent/Workflow，12 小時沒完成通知就丟）、`tokens`（message.id 去重，TokenTally 增量掃描），來源都是 transcript（Activity.swift）。交辦中超過 10 分鐘不算卡住。畫面按需渲染：只有「改檔」打字是持續動畫，其餘短動畫 playFor 播完就停；滾輪＝沿鏡頭→轉軸縮放（SceneKit 預設是平移）。等你的角色點一下開回答卡；送出 `BoardActions.answer`：有 tmux 打字 → 沒有就 Peer 直送（跟派工同一條）→ 都不通才拷貝。`BoardStore.readAll` 加 mtime 快取（DecodeCache）。量測（10-20）：正式版有 AI 在工作時 30 秒平均 10% → 3.4%；凍結資料閒置 2.3%，剩下是 1.5 秒輪詢本身 ⇒ 同日改 FSEvents 事件驅動（BoardWatcher，0.3 秒合併；每 15 秒保底給「看時間」的判斷），看板自己寫的 roster.json／history.jsonl 與原子寫入暫存檔（.sb-）要排除，否則自己叫醒自己（實測 27 秒刷 73 次）；改後測試視窗 30 秒 0.6%。`SHOWORK_BOARD_TRACE=1` 印每次刷新與觸發路徑。
- 3D 辦公室第三版資料層（10-20，`ShoWorkCore/Office.swift`）：房間規則＝固定樓層＋活動區。`ResidentProjects.scan` 列 `~/github-repos` 第一層、30 天內有 commit 的 repo（讀 `.git/logs/HEAD` 尾端，只認 commit／merge／pull／rebase／cherry-pick／revert／am，不算 checkout／reset／clone；沒 reflog 看 `refs/heads` mtime；不開 git 子行程）；符號連結（SD 卡冷資料）、worktree（`.git` 是檔案）不算常駐。名稱＝資料夾名，跟 `Board.projectName` 一致。只在啟動與每 30 分鐘重算（掛在 15 秒保底那條讀檔路徑上比時間）；不監看 `~/github-repos`（build 產物事件太多）。`OfficeDepartments.build` → 常駐照名稱（`localizedStandardCompare`）＋臨時接在後面，`BoardModel.departments`。前台・保全：`WifiWatch.parse`（名冊 `~/.claude/data/wifiwatch_devices.json`＋紀錄 `wifiwatch.log`）→ `GuardStatus`（上次掃描＝最新 last_seen、在線＝差 2 分鐘內、未命名／NEW／★待確認、正常／注意／警示，24 小時沒掃＝注意），`BoardModel.guardStatus`；兩個檔加進 `BoardWatcher.relevant()`。立即掃描 `BoardModel.guardScan()`→`BoardActions.guardScanner`（`GuardScanner`，同時只跑一個，zsh 跑 wifiwatch.sh）；定時巡邏 `office.guardPatrol`（預設關，只有正式 agent、每 30 分鐘最多一次）。設定 `OfficePrefs`：`office.layout` grid｜ring、`office.lighting` day｜night｜auto（auto＝18:00–06:00 夜晚，`nextChange` 給一次性排程）。除錯：`--office-dump`、`--guard-scan`（沒設 `SHOWORK_WIFIWATCH_SCRIPT` 假腳本又沒帶 `--real` 就拒絕）。`BoardWatcher` 路徑改用 realpath（`resolvingSymlinksInPath` 會把 /private/tmp 變 /tmp，測試資料夾事件全對不上）。注意：沙箱裡跑的測試收不到 FSEvents。
- **外部相依：wifiwatch**（10-24）：保全的資料來自 Kang 的共用工具 `~/.claude/scripts/wifiwatch.sh`＋`wifiwatch.py`（不在本 repo、不是 git）。ShoWork42 只讀名冊 `~/.claude/data/wifiwatch_devices.json`（MAC → `first_seen`／`label`／`vendor`／`last_seen`／`last_ip`／選填 `hostname`／`ipv6_only`／`same_as`）和 `wifiwatch.log`（`NEW` 行），「立即掃描」跑 `wifiwatch.sh` 不帶參數。改那支工具前先備份，五種用法（掃一次／`--watch`／`--label`／`--list`／`--forget`）要各跑一次。10-24 加了 IPv6 mDNS 反查主機名＋同主機名的隱私位址自動沿用名字（`same_as`＝來源 MAC，紀錄寫 `SAME` 行）。
- 3D 辦公室第三版畫面（10-20，`OfficeBuilder.swift`＋`OfficeVoxel.swift`）：像素沙盒風（示意 `~/Desktop/3D辦公室格局示意`）。`OfficePlan.make` 依第 1 棒的有序部門清單算位置：grid 一格 7.4×6.2 公尺（6 座位也放得下，有人進出不推動別的部門）、常駐部門對半分前後兩區、中間走道放咖啡吧／會議桌／隊長台；ring 常駐部門每個佔 5.8 公尺弧長、座位多往外長，中央一塊草地廣場放公共區。**固定樓層＋活動區**（10-20 審查修正）：樓層大小、常駐部門位置只看常駐部門數，臨時部門放活動區（grid＝接在前區後面往入口長；ring＝廣場前後、從中間往兩邊排），臨時部門進出不會移動任何常駐部門（PROBE 印 `office residents` 可比）；樓層大小變了只有在你沒動過視角時才重新取景。取景 `OfficeBuilder.fit` 用投影真的算（原本粗估，環狀格局入口被切掉）。座位依卡片 id 排（不因狀態換座位），4／6 張桌子兩兩面對面（坐不下的站柵欄邊），偶數號坐後排面向預設鏡頭；角色放大 1.3 倍、螢幕降到 1.08 公尺以下，坐著也比螢幕高。休息（idle）的去咖啡吧（8 個位置，多的留在桌上）、隊長坐隊長台。**省電結構**：整層樓靜態家具用 `VoxelMesh` 依材質合併成一個 geometry（一種材質一個 element＝一個 draw call），地毯另一批（有人／沒人換色只重建這批）；材質一律走 `VoxMat` 快取，發光材質記白天／夜晚強度，切燈光只改強度＋燈光＋背景（`setNight`），不重建。部門名單／座位數／格局變了才重建靜態層，其餘只換那個人、那面看板、那塊木牌。夜晚 omni 最多 8 盞（燈籠其他只靠發光材質），HDR／bloom 只在夜晚開。部門看板只在鏡頭 30 公尺內顯示，在鏡頭停下來時算一次（`updateLOD`，掛在 playFor 到期那一次 asyncAfter 上）。點擊用 `categoryBitMask`（角色／保全）只測角色，不在大 mesh 上算三角形。像素材質一律直接寫 RGBA 位元組（`NSBitmapImageRep.setColor` 遇 sRGB 會整張貼圖失效、方塊不畫）。入口保全：監控螢幕＝`GuardStatus` 等級色、頭上 ✓／?／!／📡、掃描中天線寶石轉（只在掃描時持續渲染）；點保全開 `GuardCard`（上次掃描、在線數、要注意的裝置、立即掃描、定時巡邏），停上去 `GuardHover`。右上角兩個選單：格局、燈光（存 `office.layout`／`office.lighting`；測試視窗只放在記憶體不寫回）；自動燈光到 06:00／18:00 用一次性 `Task.sleep` 重算，不輪詢。`BoardModel.loaded`：辦公室在第一次讀到卡片前就畫出來，讀到之前不算「第一次載入」（不然一開就飛鏡頭）。測試變數：`SHOWORK_OFFICE_LAYOUT=grid|ring`、`SHOWORK_OFFICE_LIGHTING=day|night|auto`、`SHOWORK_OFFICE_GUARD=normal|notice|alert`、`SHOWORK_OFFICE_GUARDCARD=1`、`SHOWORK_OFFICE_GUARDSCAN=1`（1.5 秒後按立即掃描；測試視窗沒設 `SHOWORK_WIFIWATCH_SCRIPT` 假腳本會拒絕）、`SHOWORK_OFFICE_FOCUS=<id>|guard`＋`SHOWORK_OFFICE_FOCUS_DIST`、`SHOWORK_OFFICE_STATS=1`（SceneKit 統計列）、`SHOWORK_OFFICE_TOGGLE=1`（2 秒後走選單同一條 binding 換格局＋換夜晚，不寫回設定）；PROBE 另外印 `office stats`（節點、估計 draw call、燈數、材質數）、`office residents`（常駐部門位置）、合成 W 鍵。保全判讀補充（10-20 審查）：只有 IPv6、MAC 是隨機（本機管理位元）的沒命名裝置＝多半是家裡手機的隱私位址，在線只算「注意」不算「警示」（真實名冊有 3 台這種，原本保全一直亮紅燈）。`BoardWindow.snapshot` 會把 SwiftUI 疊層（卡片、選單）補回 3D 截圖上。量測（10-20，1600×1000 測試視窗）：示範 21 人 nodes 378／draw call≈265、真資料 6 人 191／≈128；閒置（沒人打字）CPU 10 次平均 ≈0.1%、RSS ≈248MB；有人打字（持續 12 fps）白天 ≈3.2%、夜晚 ≈4.5%。
- 測試視窗（10-20 Kang：不准開到他的螢幕上）：`--board-window` ⇒ `BoardWindow.testMode`，OffscreenWindow 放在所有螢幕外、不 activate、不記位置；`SHOWORK_TEST_SIZE=WxH`、`SHOWORK_TEST_SHOT=<png>`＋`SHOWORK_TEST_SHOT_DELAY` 由程式自己存圖（screencapture 拍不到螢幕外視窗；螢幕外 SceneKit 不推進動畫，所以第一次取景直接定位）。其他測試變數：`SHOWORK_OFFICE_DEMO=all|idle|camera`、`SHOWORK_OFFICE_FOCUS`、`SHOWORK_OFFICE_ANSWER`、`SHOWORK_OFFICE_TRACE`、`SHOWORK_TEST_VIEW=islands|office`；`--board-act answer <sid> <文字>`。
- 驗收（10-08）：開 3 個 session（長任務／問問題／秒回），看板分別落在進行中／待審（等你回答）／待審（做完了，你還沒看）；送出排隊訊息出現在待辦；與實際一致。

- 科技大樓資料層（10-20 第 2 棒，規範 `docs/design/office-tower/設計規範.md`）：`ShoWorkCore/Tower.swift`（`TowerPlan.build` 由下往上：大廳 01→閒置薄層（一層 8 塊門牌、最多 3 層、溢出「+N」）→有 AI 的專案樓層→頂樓 RF；`TowerRegistry` 固定樓層號存 `board/tower.json`，第一次依 7 天用量（`ProjectUsage.scan`：7 天內改過的 transcript 檔大小）排名、之後新專案接尾端不重排；全部 AI 關掉滿 2 小時才降樓，`nextDemotion` 給一次性重算；`TowerPlan.moves` 給搬家清單）、`TowerTheme.swift`（16 主題、`WorkSignature` 本地評分、`DecorPrompt`、`DecorPolicy`／`DecorLedger` 節流、`ThemePicker` 快取 `board/themes/<專案>.json`＋`board/decor_ledger.json`）、`Wander.swift`（`WanderPlanner.plan`，session id＋15 秒時段當種子）。Agent 端 `TowerSource.swift`：`DecorRunner`（`claude -p --model haiku --tools "" --strict-mcp-config --no-session-persistence --system-prompt …`，空 cwd、`SHOWORK_REVIEWER=1`）、`TowerDecor`（一輪結束偵測、收集線索，只有正式 agent 呼叫 AI／寫檔）。`BoardModel.tower／towerMoves／decor／wander／wanderVisible／redecorate(_:)`。`tower.json`、`themes/`、`decor_ledger.json` 已排除在 `BoardWatcher.relevant()` 外。除錯：`--office-dump`（樓層表、主題、閒晃，不存檔）、`--decor-pick <專案> [--real] [--save]`。
- 科技大樓畫面（10-20 第 3 棒，取代第三版的棋盤／環狀格局；`office.layout` 設定鍵留著但不再讀）：`OfficeTower.swift`＝零件（色票 `TP`、主題家具 `TowerProps`（15 主題＋通用庫，方塊尺寸照規範 §2）、`PropPlacer`（AABB 不重疊、放不下的丟掉、門牌與左右端先佔）、樓層模組 `TowerModules`（專案層／閒置薄層／大廳／頂樓）、`TowerCore`（結構柱、電梯井、溜滑梯整條一個 mesh、地面與天際線白天夜晚各一份）、`MoveAnim`／`TripPath`（customAction，不綁主執行緒，播完 `DispatchQueue.main` 回來））；`OfficeBuilder`＝照 `BoardModel.tower／decor／wander` 組大樓：一層一個模組節點（靜態合併成一個 VoxelMesh，四面牆各一個節點，門牌一個節點），內容鍵（主題、桌數、有沒有人、門牌）變了才重建那一層；樓層 id／y 變了且看得到 ⇒ 搬家動畫 2 秒（24 fps），不然直接到位。角色是所在樓層模組的子節點（搬家跟著走），閒晃時掛到 world 上跑 `TripPath`（10 fps），走完回到座位／頂樓；搬家開始或視窗被蓋住 ⇒ 路上的人直接落地（`settle`）。cutaway／門牌換牆／夜晚 omni 指派（大廳、頂樓＋離焦點最近 4 層，共 ≤6）都在鏡頭停下時算一次（`camMoved`→`updateLOD`，跟動畫的 `playFor` 分開排程）；閒置薄層的門牌條貼在靠鏡頭那面（後牆會被上一層樓板擋住）。`OfficeSCNView` 把視窗可見狀態回報給 `BoardModel.wanderVisible`。點擊盒改成 isHidden（hitTest 用 ignoreHiddenNodes: false），每人少一個 draw call。測試變數：`SHOWORK_OFFICE_MOVE=<專案>[@秒]`（定在剛升上來第幾秒）、`SHOWORK_OFFICE_FOCUS=roof|lobby|floor:<專案>`、`SHOWORK_OFFICE_AZIMUTH`／`SHOWORK_OFFICE_ELEVATION`（取景角度）、`SHOWORK_OFFICE_TRIP_T`；量測 `--office-bench walk|move|still [秒] [fps]`（SCNRenderer 畫進螢幕外貼圖，不開視窗）。量測（10-20 第 3 棒原始數字，第 4 棒已重量見下一條）。
- 科技大樓審查修正（10-20 第 4 棒）：①正面直框、大廳入口門框原本併在靜態 mesh，cutaway 後還留著、近看黑線切過角色的臉、框住保全 ⇒ 改成正面 cutaway 節點的一部分（`glassFront(mullionsAt:extra:)`，規範 §3.6「front＝玻璃＋直框」）；側牆門框拿掉（素牆開洞，放進牆節點會每層多一個 draw call）。②牆原本淡到 0.06 照樣畫 ⇒ 淡到 0 後設 `isHidden`（`cutFade` 0.25 秒；`--office-bench` 設 0，因為 SCNRenderer 的隱式動畫走不完，第 3 棒量到的是前牆還在的畫面）。③新建／重建的樓層與核心直接套用目前的 cutaway（`cutNow`），不再先閃一下整面玻璃。④溜滑梯拆成獨立 cutaway 節點（`Facade.cut` 0.75：只有從右側看才藏，右前方預設視角照樣看得到）。⑤夜景窗光條暗一半、短一點、少一點（背景退後，素色）。⑥臨時部門（不在常駐名冊）AI 一關原本樓層立刻消失、沒有 2 小時緩衝 ⇒ `TowerPlan.build` 把名冊裡還在緩衝中的補回來（燈暗著，滿 2 小時消失、不進薄層；有測試）。⑦同一次刷新同一層一起出發的人錯開 `WanderPlanner.stagger` 2.5 秒（原本三人走同一條走道疊成一團；有測試）。量測（第 4 棒，凍結資料、測試視窗、每 2 秒 ps 10 次＋20 秒累計 CPU 時間）：辦公室閒置 0.30%／同條件部門島 0.30%（兩次交替），真資料 0.25%，閒置時 `office playing false`；RSS 辦公室 226MB（真資料 276MB）／部門島 89–175MB。draw call：示範 21 人 ≈335、真資料 6 人 ≈208。bench（單核、不含合成與 GPU、系統負載約 3）：閒晃 3 人 10 fps 3.7%、搬家 24 fps 8.4%、一直畫 12 fps 4.2%（同條件第 3 棒的執行檔 4.0–4.2%，差別是系統負載不是程式）。
- 科技大樓 UI/UX 優化（10-20 晚，規劃 `docs/design/office-tower/UIUX優化規劃.md`；第 2 棒實作、第 4 棒依評審修正）：文字一律畫在螢幕空間，3D 只管空間與氣氛。①`ShoWorkCore/TowerHUD.swift`（純函式、有測試）：`AttentionSummary`（頂部「需要你」列計數與輪流順序）、`TowerIndex.rows`（左側樓層索引列）、`LabelLayout.place`（標籤避讓：6 個候選位置→在自己那層裡挑離頭最近的空位；`LabelBox.ceil／floorY`＝那層天花／地坪在畫面上的 y，標籤不越層；`fixed`＝先放好的樓層名當障礙物；等你／卡住／做完／保全一定找位置，工作中／休息擠不下收進那層「+N」，收起來的有必顯的就紅底「! +N」）。②`ShoWorkAgent/OfficeLabels.swift`：疊在 SCNView 上的 CALayer（`LabelHostView`，不吃滑鼠），位置只在 `SCNSceneRendererDelegate.didApplyConstraints`（真的有畫一幀）時算，有變才回主執行緒改圖層 ⇒ 閒置不渲染時零成本、不加 timer（SpriteKit 版閒置 CPU 3–4%，已換掉）。樓層名貼在「面向鏡頭那一面」的左上角（轉到側面也對），樓層左角在畫面外時沿樓板前緣取畫面左緣那一點；樓層不在畫面裡就不畫（不夾到畫面頂端，避免錯標）。人的天花＝錨點朝鏡頭水平走到大樓外緣那點的天花投影；轉到側面、頭已被上一層樓板擋住時改用人所在深度的天花。點標籤＝點角色（`OfficeSCNView.pick` 先問標籤再問 3D）。左下角開著卡片時那塊不畫標籤（`setOccluder`）。③`OfficeView`：`AttentionBar`、`FloorRail`（點樓層 `frameFloor`：框這層的人＋左右一段，直式視窗樓層高佔畫面 ≥45%；閒置薄層框整層寬）、`OfficeHelp`。④3D 文字全部拿掉：專案樓層、大廳、頂樓、閒置薄層的門牌，子 agent 頭上小字牌（改成名牌後面「・子 agent N」），思考泡泡的「…」改成方塊點。⑤`OfficeTower`：每個主題一件識別色★大件 `hero_<主題>`（2.0×0.66×≤1.25，角色左前方前帶，只用既有材質）、後牆協作區 3 公尺刷識別色、休息區三種輪流（`TowerProps.common(樓層號)`：咖啡角／沙發＋飲水機＋影印機／小會議桌＋長凳）、1–2 人的樓層補空桌湊滿第一排、每張桌 2 件桌面小物（含第二螢幕）、電梯門框與往溜滑梯的門框、溜滑梯縮進右後角後面（`TD.slideX/Z` 4.9／−3.65、起點角 `slideA0` 朝門）。⑥預設取景 `frameRange`：只露頂樓樓板一條線（不切半截樹）；保全注意以上框到大廳 0.4 高（閒置薄層的下限只在保全正常時套用）。⑦測試截圖 `BoardWindow.snapshot`：「空底顏色」改取 3D 區域四角＋中央的眾數（標籤剛好蓋在正中央時整片 3D 會被蓋掉）。測試變數：`SHOWORK_OFFICE_ATTN`、`SHOWORK_OFFICE_RAILCLICK=<樓層 id>`、`SHOWORK_OFFICE_PROBE_DELAY`、`SHOWORK_OFFICE_LABELS=off`、`SHOWORK_OFFICE_RAIL=off`、`SHOWORK_OFFICE_HELP`；PROBE 另印每層畫面高度（點／%W／%H）、標籤數、重疊數、離頭最遠距離（`far=[…]`）、越層數（`outOfFloor`）、逐一點標籤結果。量測（第 4 棒，真資料 6 人、960×1050）：draw call ≈216、材質 65、夜晚燈 8；示範 21 人 ≈309（材質 74）；閒置 60 秒累計 CPU 0.31 秒（0.52%，關掉標籤 0.47%，差在量測誤差內）、RSS 249MB。
- 外部空間城市（10-21，`ShoWorkCore/City.swift`＋`ShoWorkAgent/CitySource.swift`＋`OfficeCity.swift`）：大樓四周地面一圈街區，把這台 Mac 的外部資源畫成建築。硬碟＝貨櫃堆場（`URLResourceKey` 讀容量，不跑 df；內建碟用 `/` 的 important usage；/Volumes 排除 Recovery／Preboot／VM／時光機；層數＝已用比例×4 進位，≥90% 堆到圍籬外＋倉庫頂紅燈，狀態剛變時轉 4 秒；看過的外接碟名稱存 `ai.okle42.showork` 的 `city.knownDisks`，拔掉＝鐵捲門拉下、路斷掉）、雲端＝飛艇（iCloud Drive 資料夾在不在、`~/Library/CloudStorage` 每個資料夾一艘，名字去掉「-帳號」；同步狀態 macOS 不給讀，一律「狀態未知」）、ssh Host＝對街分公司（`~/.ssh/config`，每 60 秒對 Port（預設 22）一次 2 秒逾時的 NWConnection TCP connect）、防火牆＝城牆（每 5 分鐘 `socketfilterfw --getglobalstate`＋`lsof -nP -iTCP -sTCP:LISTEN`：只綁 127/::1＝城內關著的門、其他＝對外城門、9888 audio-bridge＝敞開的紅門；關＝前牆缺口）、cool42＝電廠（煙量 10°C 一格、差 6°C 以上或等級變了才重畫；hot 以上紅）、GitHub＝港口（每 60 秒批次讀 `~/github-repos/*/.git/refs/remotes/origin/**`＋packed-refs 的 mtime，變新就一艘船出港 4 秒，playFor；第一次只當基準；符號連結的 repo 不碰）。收集全在 `showork.city` 背景 queue，掛在看板 15 秒保底 timer（`CityMonitor.tick`）＋掛載通知，沒有新 timer；`CityState` 有變才發布（`BoardModel.city`），`CityBuilder` 內容鍵變了才重建（整個城市一個 VoxelMesh，約 25 draw call）。名牌走 OfficeLabels（`LabelKind.city`／`.cityAlert`，警示跟等你同級；大樓每層投影框當障礙物，名牌不壓大樓）；樓層在畫面上太小（俯瞰）時等你／卡住的名牌改短字只留名字。頂部「N 設備警示」（≥90%、離線、防火牆關、敞開紅門、hot）輪流飛過去開細節卡；左側索引列最下面「城市」＝俯瞰（再點回預設）；保全卡多一行城牆摘要。順手修：鏡頭 zNear／zFar 原本寫在註解裡沒生效（實際 zFar 100，拉遠會切掉），改成 1／500。測試變數：`SHOWORK_CITY_DEMO=1|calm`（示範值）、`SHOWORK_CITY_SHIP=<repo>`（定在出港第 1.5 秒）、`SHOWORK_CITY=off`、`SHOWORK_CITY_TRACE=1`、`SHOWORK_OFFICE_RAILCLICK=city`、`SHOWORK_OFFICE_CITYCARD=<id>`、`SHOWORK_SSH_CONFIG`。
- 3D 環境稽核（10-21）：遠景大樓剪影拿掉（環境只剩大地面，日夜共用一個 dayNight 材質）；飛艇降到 6.2 公尺、機頭繫在繫留塔上；城門以正門（x 2，對準大樓前那條路）為中心左右交替排，沒有對外埠＝正門關著；路穿過城門接到街；路燈避開所有開口；堆場的路接到電梯井外側匯流道再接到大樓前廣場；電廠加正門與路；港口貨櫃改放棧橋末端、水面往東延伸到 x 44（船不會開上岸）、加另外兩邊的岸；樓層看板掛在立柱上（`TD.boardX` −10.6，看板繞柱轉、不再插進電梯井；立柱只在有看板顯示時出現）；Wi‑Fi 天線移到前台檯面上；頂樓長椅站位往前 0.15。標籤：大樓在鏡頭背後／整棟在畫面外時不畫樓層名；「+N 人」避開已放好的名牌；閒置名字列用兩角較嚴的上下緣；被大樓擋住的城市名牌不畫；「需要你」列依寬度退成短字／只剩數字。鏡頭 `look(at:)` 一律帶世界向上向量（原本側面取景會歪）。測試變數 `SHOWORK_OFFICE_CAM=方位,仰角,距離[,tx,ty,tz]`（度、公尺）。
- CPU 突波修正（10-21）：①樓層看板貼圖只在鏡頭 30 公尺內要顯示時才畫（token／ctx% 變了只記「過期」，預設鏡頭不重畫）②對話紀錄尾端改增量解析（`TranscriptInfo.Parser`，只餵新增完整行；餵超過 512KB 整段重來，維持只看尾端的語意）③`FileManager.attributesOfItem` 全換成 `FileStat.lstat`（前者每次讀延伸屬性，取樣裡 getxattr／listxattr 是讀檔路徑的大宗）、`BoardStore.readAll` 路徑改字串接 ④`CaptainStore.tasks()` 加 mtime 快取 ⑤`BoardModel.refresh` 兩輪至少隔 1 秒。量測（測試視窗 960×1050、真資料、60 秒累計 CPU，新舊版同時跑）：AI 忙時 舊 4.4–9.0% → 新 2.7–4.8%（看板重畫 5–14 次／分 → 0、刷新 38–80 → 27–42 次）；安靜時 1.3–1.6% → 0.9–1.1%。draw call（預設鏡頭、真資料 6 人）夜晚 281 → 277、白天 280 → 277。
- 城市第二輪（10-21，電視上看到的問題）：①堆場旁「一坨歪斜互插的貨櫃」根因是資料錯：FAT32 隨身碟（NO NAME）的 `volumeAvailableCapacityForImportantUsage` 回 0，4 GB 空碟被當成 100% 滿 ⇒ 溢出貨櫃＋紅燈；`CityParse.available` 改成重要用途可用為 0 時用一般可用（有測試），不到 0.5% 寫「<1%」。溢出貨櫃改成整齊排在出口路兩側（`CityBuilder.overflowSlots`，一側兩個、多的疊第二層）。城市裡所有轉角度的方塊（城牆缺口碎塊、敞開紅門門板、斷路碎塊）全改方正擺。穿插稽核 `SHOWORK_CITY_AUDIT=1`：重建時把轉角度的方塊與貨櫃／警示燈／起重機跟城市每個方塊用 `CityBox.penetration`（Core，分離軸，有測試）比，插進去超過 1 cm 就印（修完示範與真資料都是 0 處）。②「十字架」＝倉庫頂的警示燈（紅方塊＋一根 0.9 公尺橫桿）⇒ 改成底座＋燈罩＋燈帽、狀態剛變時閃 4 秒；港口起重機（一根柱＋橫臂＋吊索，正面看也像十字架）⇒ 四腳龍門吊＋往水面伸的吊臂＋機房＋台車吊具。③iCloud：每 5 分鐘在 `showork.city` queue 跑 `brctl quota`、`brctl status com.apple.CloudDocs`、`brctl status`（各 10 秒逾時），`CityParse.brctlQuota／brctlStatus／cloudSync` 解析（有測試，假容器名）：名牌「iCloud・剩 92G」；主容器非 idle 且 1 小時沒同步成功＝卡住、其他容器 blocked-*（App 已刪除的不算）＝被擋、剩不到 5 GB（總額度讀不到，用絕對值）才警示並進設備警示；不 du `~/Library/Mobile Documents`（可能跳 iCloud Drive 隱私權限視窗）。其他 CloudStorage 只寫「已連線」。不再出現「狀態未知」。④懸停卡：滑鼠停在城市建築或名牌上浮出 `CityHoverCard`（內容元件 `CityDetail` 跟點擊細節卡共用），位置 `OfficeView.hoverOrigin` 夾在 3D 區域內；hover 偵測只在 mouseMoved、50 ms 節流（尾端補一次一次性 asyncAfter）；卡片讀 `CityMonitor.latest`（含不發布的伺服器延遲、上次連上）。磁碟多了一般可用、檔案系統、掛載點、拔掉的最後看到時間（`city.diskSeen`，插拔名單變了才寫）；lsof 加 `+c0` 程式名不截字；港口列最近 5 個有新遠端 ref 的 repo。家目錄最大資料夾不做（掃 Desktop／Documents／Downloads 會跳隱私權限視窗、掃 Library 要數十秒）。測試變數 `SHOWORK_OFFICE_HOVER=<城市 id>[,label]`＋`SHOWORK_OFFICE_HOVER_DELAY`。量測：預設鏡頭 draw call 真資料 249（日夜）、示範夜晚 256；測試視窗閒置 60 秒 fa41a57 0.73% vs 本版 0.76%、2ca4226 0.56% vs 本版 0.38%。

## 戰情中心 P2（10-08）：自報、AI 審核、你的決定、帳號流量

- **自報**：安裝時加 SessionStart hook `showork brief`，把一段說明注入每個新 session；AI 每輪結束跑 `showork card --status review|done|blocked|working --progress --confidence --summary [--ask] [--report]`，存 `board/cards/<sessionId>.json`（sessionId 取 `CLAUDE_CODE_SESSION_ID`）。早於你最後一次送出訊息的自報不算。`claude -p` 無頭呼叫（`CLAUDE_CODE_ENTRYPOINT=sdk-*`，例如熬夜秘書、審核員自己）不注入、不上看板。
- **審核**：卡片進「待審」（等你回答的除外）就請 `claude -p --model sonnet` 唯讀查證（Read／Grep／Glob／git status·diff·log·show），輸出完成度、信心度、pass／concern／fail、最多 3 條疑點，存 `board/reviews/`。同時最多 2 個；保險絲：同一 session 一小時最多自動審 3 次。實測一次約 20 秒、US$0.02。看板上有「AI 審核」開關。
- **決定**：放行 → 完成；丟待辦（可加備註）→ 待辦；存 `board/decisions/`，該 session 一有新動靜就失效。退回＋補一句 → 用 tmux `send-keys` 打進那個 pane 並按 Enter（不在 tmux：拷貝到剪貼簿並跳到視窗）。新任務 → `claude --bg`（資料夾要先信任過）。
- **帳號流量**：Claude Code 只把 `rate_limits` 交給 statusLine，所以由狀態列腳本存 `~/.claude/cache/rate_limits.json`，看板右上角顯示 5 小時／7 天用量與重置倒數（≥70% 橘、≥90% 紅）。**給別人用時要附一個會存這個檔的 statusLine**，不然右上角顯示「尚無資料」。
- **時間一律存到毫秒**（`BoardJSON`）。10-08 曾只存到秒，審核記的「這一輪」永遠比實際早不到 1 秒，結果每 20 秒重審一次、連審 14 次。
- 驗收入口：`ShoWorkAgent --board-act <approve|park|sendback|review> <sessionId> [文字]`、`--board-act newtask <資料夾> <提示>`，跟按鈕走同一條路。

## ctx 顯示、快滿收尾與自動交接（10-09；10-24 閉環）

- 狀態列腳本（`~/.claude/scripts/statusline.py`）把每個 session 的 `context_window.used_percentage` 存成 `~/.claude/cache/ctx/<sessionId>.json`；卡片在完成度／信心度後面顯示 `🧠 Nk`（token 數；到門檻 8 成起橘、到門檻紅）。狀態列只在那個 session 有互動時更新，久沒動的 session 先不顯示。
- 超過 token 門檻（`board.ctxTokens`，250k–1000k；10-29 Kang 改成只看這一個條件）：系統通知一次；「自動收尾」開著（預設）時，等那個 AI 停下來（不在工作中、不在問你問題）就打一段收尾指令進它的 tmux pane：commit、**規則允許才 push**（push 與否交給那個 session 的 AI 依 repo 規則判斷，看板不自己跑 git）、更新交接與記憶。每個 session 只送一次（`board/ctxguard.json`）；卡片上也有手動「收尾」按鈕。
- 只有正式 agent 會通知、會打字；`--board-window` 測試視窗不動手。
- 實測（10-09）：把測試 session 的 ctx 檔改成 90%，1.5 秒內通知＋送出，該 session 自己 commit 兩筆、因沒有 remote 不 push、寫了 HANDOFF.md。

### 自動交接閉環（10-24，T1024155358）

Kang 原話：「讓他工作超過 70% 以後就自動收尾…自己準備交接文件，處理好之後自己再接手自己的交接文件」。10-18 起 Stop hook 已會請它收尾，但收尾後沒人 /clear（10-24 早上 Quinn 收尾在 72%，又被派工做到 80%）。現在三段接起來：

1. **收尾**（`~/.claude/scripts/hook_ctx_wrapup.py`，Stop hook）：ctx ≥ `board.ctxTokens`（token 數，250k–1000k，預設 250k；10-29 起只看這一個條件，% 門檻已拿掉）時 block、請 AI commit／規則允許才 push／更新交接，最後一步發 **收尾卡** `showork card --kind wrapup --handoff <交接文件絕對路徑> --summary "<接手重點>"`，發完就停。收尾卡一定要帶存在的絕對路徑，否則 CLI 拒收。收尾卡寫 `board/handover/<sid>.json`（`HandoverRecord`，pending；記 claude 行程 pid＝往上第一個有 `~/.claude/sessions/<pid>.json` 的祖先——行程名是版本號 `2.1.310` 不是 claude，10-24 實測）。
2. **自動 /clear**（agent `HandoverClear`，每次刷新）：pending 而且 ① 它最後一張卡就是收尾卡（之後又發卡＝還在做或在問問題）② 不在工作欄 ③ 沒開權限對話框、不是「等你回答」④ 停了 5 秒 ⑤ 鍵盤 60 秒沒動（全系統；隊長 10-24 要求，免得 Kang 正在那個分頁打草稿時被接上 /clear）⇒ 送 `/clear`：
   - tmux：claude 行程的 tty 擁有的 pane，`send-keys`。
   - Ghostty（沒 tmux）：用 OSC 7 nonce 從 tty 探出那個分頁的 AppleScript terminal id，再比對 terminal 標題開頭是它的英文名（`Handover.titleMatches`），兩道都對才用 `input text … to terminal` ＋ `send key "enter"` 送——**不搶焦點、不動視窗**。
   - 其他終端機／驗不過：不送，記 failed、卡片寫 blocked、系統通知請 Kang 手動 /clear。
   - 送鍵前先把紀錄改成 clearing（/clear 後 SessionStart 會改寫同一筆，晚寫會蓋掉它，10-24 實測撞到）；`sessions/<pid>.json` 換了 sid 或紀錄變 taken ⇒ 再打一句「【自動接手】請接手 <名字> 的工作：先讀 <HANDOFF>…」讓新 context 動起來；20 秒沒換 sid ⇒ failed。每筆只自動送一次。
   - 紀錄寫 `board/handover.log`（不論有沒有 SHOWORK_DEBUG）。
3. **自動接手**（`showork brief`，SessionStart hook，原本就掛著、沒改 settings）：讀 hook JSON 的 session_id／source／cwd，`Handover.claim` 認領——compact＝同一個 sid；clear／startup／resume＝同一個 claude 行程，或同資料夾而原 session 已不在，60 分鐘內。認領後：新 sid 沿用英文名（`board/names/<sid>.json` 的 `handoverFrom` 記舊 sid）、開著的派工單 `toSession` 轉到新 sid、注入「【自動接手】你是 <名字> 的接手，先讀 <HANDOFF>…名字沿用、派工單沿用」。
- **收尾後又派新工作**：收尾到 /clear 之間使用者送出新指令（UserPromptSubmit，`showork title`）⇒ interrupted，不自動 /clear，看板傳「【交接提醒】」給隊長（沒隊長就系統通知）；ctx 再多 15% Stop hook 會再收一次。
- **看得到**：卡片完成度列多一個橘色「🔁 已收尾待 /clear」（泡泡也是）；`showork roster` 標出來；隊長巡檢列「已收尾、還沒 /clear：…」；隊長守則第 11 條。
- 開關與門檻：`board.autoWrapUp`、`board.ctxTokens`（defaults `ai.okle42.showork`；工具列「ctx 250k」點開是滑桿，250k–1000k、10k 一格）。測試用：claude 行程帶 `SHOWORK_TEST_CTX=300k` 啟動，Stop hook 就當 ctx 用了 300k token。
- **Ghostty 送字不搶焦點**（隊長 10-24 的四點疑慮逐條判斷）：Ghostty 1.3 的 AppleScript `input text`／`send key` 是直接送給指定的 terminal surface，不是 System Events 的 keystroke，**不需要把視窗拉到前面**。
  ① 使用者閒置：一律要求鍵盤 60 秒沒動才送。② 前景還原：不會改前景，所以不用還原——實測送前／送後前景都是同一個 App。③ 縮在 Dock／別的桌面空間：照樣送得到、視窗不會被叫出來或搬動，所以不用退回「通知手動」——實測縮在 Dock 的分頁送字後仍是縮著、指令有執行。真正的退回條件是「驗不到目標」（tty 探不到分頁、標題對不上英文名、不在 tmux 也不在 Ghostty）。④ 測試只用自己開的 Ghostty 視窗：等使用者閒 20 秒才開、開完立刻縮到 Dock（只縮名字唯一對得上的新窗）、焦點還給原 App，測完以 terminal id 關掉。
- 實測（10-24，假專案「專案A」、Haiku 測試 session，`SHOWORK_TEST_CTX=72`）：
  - tmux（看不見的 `tmux -L swtest`）：Stop hook 請收尾 → AI 寫 HANDOFF.md、發收尾卡 → 看板 1–2 秒內送 /clear → 新 sid 沿用名字 Wade（`handoverFrom` 記舊 sid）、假派工單 TTEST1024 的 `toSession` 換成新 sid → 新 context 的 SessionStart 帶【自動接手】提示、第一則使用者訊息是看板打的接手句、ctx 5%（只剩系統提示）。第一次失敗兩個：claude 行程名是 `2.1.310`（pid 記成 0 → 改找 sessions 檔）；SessionStart 改寫紀錄蓋掉看板的「已送」→ 接手句沒送（改成送鍵前先記）。
  - Ghostty（自己開、縮在 Dock 的視窗）：同樣流程，/clear 與接手句都經 AppleScript 送達，名字 Xena 沿用、ctx 5%；前景 App 全程沒變。

## P3 隊長派工（10-09）

你只跟一個「隊長」session 講話，隊長看名冊決定交給哪個 session。原本排的「多台電腦」順延成 P4。

- **傳話走 Claude Code 內建的跨 session 訊息（`SendMessage`）**，不用 tmux 打字：訊息排進對方的收件匣，等它下一次用工具時才讀進去，不會打進你正在打字的輸入框。`notify_when_idle: true` 可以在對方停下來時通知隊長一次。tmux 打字只留給「退回」和「收尾」（你按了才做）。訊息的地址就是 `~/.claude/sessions/<pid>.json` 的 `name`（例如 `you-9e`），看板卡片標題下方有顯示。
- **看板也能直送（`Peer`）**：常駐程式／CLI 直接走同一條收件匣——讀 `~/.claude/sessions/<pid>.json` 的 `messagingSocketPath` 和 `<pid>.<hash>.key` 的 `peerToken`，連上後送一行 `{"type":"auth","token":…}`、一行 `{"msgV":1,"type":"user","priority":"next","from":"uds:…","message":{"content":"<cross-session-message …>…"}}`，對方不回應（10-09 在 2.1.290 用轉送記錄器實測 SendMessage 得到的格式；內部格式，改版可能失效，失效時 CLI 印出全文改用 SendMessage）。
- **⚠ 必要設定 `"crossSessionInbound": "accept"`**（`~/.claude/settings.json`）：看板不是 session，訊息沒有附「寄件者權限模式」，略過權限的 session 會把它**扣住等使用者在那個視窗按同意**（紀錄裡是 `Held peer message … The sender did not attest its permission mode`）。Kang 10-09 選擇全域開 accept（原檔備份 `settings.json.bak_20261009_crossSessionInbound`）。**不可**在訊息裡假造 `from-mode` 繞過檢查。賣給客戶時要說明這個取捨並由客戶自己決定。
- **自動回報隊長、自動接力（`TaskRouter`）**：單子變成 完成／要你看／卡住 時，傳一則「【派工回報 單號】」給隊長（同一狀態只傳一次，`notified`）；隊長不在就發系統通知。`task add … --then-to <B> --then "…"`：A 回報完成時自動開單給 B，附上 A 的回報（`followUp`／`after`）。只有正式 agent 會送。
- **看板按鈕**：卡片右鍵「派工給它⋯」（可設接力）；上方「交給隊長⋯」把一件事丟給隊長，由它選人。
- 實測（10-09）：接力單 9e →（自動）88，兩則回報都自動回到隊長，全程沒有人工介入。
- **名冊**：agent 每次刷新把卡片加工後寫成 `board/roster.json`；`showork roster` 印出每個 session 的名字、專案、欄位、在做什麼、ctx、交給它的派工單。超過 30 秒沒更新就當作 agent 沒在跑。
- **重工警告**：同一個專案名（往上找 `.git`）有兩個以上 session，卡片上顯示「同專案還有 ⋯」（橘色），名冊也會標。隊長自己、家目錄、看不出專案的不算。
- **派工單**：`showork task add --to <名字> --text "…"` 建 `board/tasks/<單號>.json`，印出要用 SendMessage 送的全文（第一行「【隊長派工 單號】…」，最後附回報方式）。對方回報用 `showork card --task <單號> …`，CLI 直接更新那張單（working／review／done／blocked；done 帶 `--ask` 算 review）。`showork tasks` 看狀態；`showork task cancel <單號>` 取消。
- **隊長**：`showork captain` 把目前的 session 登記進 `board/captain.json`，並印出隊長守則（先看名冊、同專案只給一個、ctx 到 token 門檻不派、建單、SendMessage＋notify_when_idle、追蹤；小事自己做；不叫別人做自己權限會被擋的事）。第一次 `task add` 也會自動登記。看板上隊長卡有「隊長」皇冠，列出派出去的單；其他卡列出交給它、還沒結束的單。

### 看板的已知耦合（b3 交接，10-09）

- 好幾處用卡片 `reason` 的字串「等你回答」做判斷（CardView 的按鈕、Reviewer 不審、ContextGuard 不插話、部門島 `Mood.of` 也認「要你決定」開頭）；改這句文字會默默壞掉，之後應改成列舉。
- `Arranger.boardFrame()` 用視窗標題「AI工作戰情中心」找看板視窗；再改名要一起改。
- 撲克牌排法的可用區上下對齊看板視窗：電視那台回報的可用區從 y=0 開始，但系統實際會把視窗推到 y=30。
- agent 被 launchctl 停掉時收到的是 SIGTERM，不會觸發 `windowWillClose`，所以「看板開著」的紀錄會保留、重啟後自動打開，這是刻意的。每次重裝 agent，看板視窗都會關掉再開。

## 收件匣與常駐隊長（10-21）
- **收件匣（InboxPanel，規則在 ShoWorkCore/Inbox.swift）**：所有「等你回答」的 AI 列在 3D 檢視右邊（視窗寬 ≥1300 固定顯示；窄的點「等你」才打開，佔掉樓層清單的位置——不疊在 SceneKit 上，圖層會透上來破圖）。「要你決定」可按選項或打字，走 `BoardActions.answer`（tmux 打字 → Peer 直送 → 拷貝）；權限對話框見下一條；AskUserQuestion 的選單只能跳到視窗。回答過、它還沒動的標「已送出」。
- **權限允許（第 2 步，ShoWorkCore/Permit.swift＋`showork permit`）**：`PermissionRequest` hook 把要做的事寫成 `board/permits/<id>.json`，收件匣顯示「允許／一律允許（只帶 permission_suggestions 裡的 addRules，套成 `updatedPermissions`）／拒絕（可附一句話，AI 收得到）」，按下去寫 `<id>.answer.json`，hook 每 0.4 秒看一次，讀到就回 decision。10-21 用 2.1.306 在虛擬終端實測：
  - 終端機對話框和 hook **同時**出現；hook 晚 15 秒才回 allow 也照樣有效 ⇒ 兩邊都能按，先按的算。戰情中心按下到指令執行約 0.3 秒。
  - 終端機先按：hook 不會被砍，之後回的 decision 會被忽略 ⇒ hook 看 transcript：先找這次的 tool_use id（同名、同輸入，從後往前），它的 tool_result 一出現就收掉（實測約 1 秒）。AI 行程死掉、等超過 1 小時也收掉。
  - 坑：從 Claude session 裡開的測試 session 會繼承 `CLAUDE_CODE_CHILD_SESSION` 等環境變數，**不寫 transcript**；e2e 要清掉 `CLAUDE*` 環境變數。
  - 安裝前就開著的 session 沒有這個 hook，收件匣仍顯示「要在終端機裡按」。
- **隊長對話（第 3 步：直接派工給隊長，ShoWorkCore/CaptainThread.swift）**：收件匣下半部原本只有「交給隊長」的輸入框，隊長的回答只在它自己的終端機裡，Kang 只好 attach 到隊長視窗。現在看板從隊長的對話紀錄尾端（1.5MB，檔案有變才重讀）整理出一串對話：
  - Kang 說的話：隊長終端機裡打的（`origin.kind == human`），以及從戰情中心送的（peer，from-name「AI工作戰情中心（使用者）」，去掉外面包的字）。
  - 隊長每一輪最後那段話（`stop_reason == end_turn` 的文字，開頭的 miniKang 提醒會拿掉）。
  - 其他 AI 的回報只留第一行（【工作回報】【派工回報】這類摘要），可以隱藏。AI 之間的自由訊息只顯示「誰傳來一則訊息」，不顯示內文。
  - 不上面板的：工具呼叫的輸入和結果、thinking、每輪中途的話。隊長審查時提醒：工具往返裡有帳號、金鑰路徑、證件檔路徑。
  - 下方列出派工中的單：還在做、3 天內有動靜的，以及 24 小時內「要你看」的；卡住的排最前面，點一下會飛到那個 AI。
  - 送出的話先顯示「送出中」，等隊長的紀錄裡出現同一句才收掉。
- **AskUserQuestion 不走權限允許**：它也會觸發 PermissionRequest，但它是選擇題不是權限。`showork permit` 看到它就不處理，交回終端機，收件匣照舊列成選單。10-22 前會顯示成「要用 AskUserQuestion，可以嗎？」加上一坨 JSON。
- **1 樓保全的 push 守門（ShoWorkCore/PushGuard.swift，`showork guard-push`）**：10-22 起只要隊長叫 push，AI 就直接推，不再等 Kang 本人按，所以保全是最後一道關。PreToolUse(Bash) hook 從指令裡找出 `git push`（會跟著 `cd`、`-C`、`X=…` 設的變數），檢查這次要推出去的 commit：
  - **擋**：ghosts、`old-history/*`、force push 或刪除 main／master、ProjectC 的 `data/`、`finance*.json`、像金鑰的字串、看不出是哪個 repo（變數展不開、不是 git 資料夾）。
  - **關鍵字**：清單在 `board/guard/keywords.txt`，只放本機、不進任何 repo，以免 ShoWork42 自己帶著客戶名字。一般 repo 命中只提醒（additionalContext）；`board/guard/strict-repos.txt` 列的公開或公司 repo 命中就擋。
  - 每次檢查都記到 `board/guard/pushes.jsonl`，保全面板顯示 24 小時內檢查幾次、擋下幾次、最近 5 筆；擋過金鑰就亮警示。
  - 擋下時 AI 看到的訊息會寫明「被保全擋下，不是 git 壞了，不要重試」、原因，以及「誤擋就找 Kang 核可」。
  - 誤擋的放行方法有兩個：Kang 在保全面板按「放行一次」（寫進 `board/guard/allow.json`：同資料夾、同 HEAD，30 分鐘內有效，用一次就失效），或自己打 `! git push`（使用者自己跑的指令不經過 hook）。
  - 測試裡的假金鑰用字串相加組出來，免得 ShoWork42 自己 push 時被擋。
- **固定英文名當收訊地址（派工 T1022020414，ShoWorkCore/Nickname.swift `ShortName`）**：UserPromptSubmit hook 的 `sessionTitle`（＝session 名＝ListAgents／SendMessage 的地址）只放英文名（Chris），doing 只進卡片標題、名冊「在做」和終端機標題（terminalSequence）。所以 `--doing` 怎麼變，地址都不變。只有 UserPromptSubmit 會改 session 名（10-22 實測：PostToolUse 不會），所以舊 session 不用重開，下一次收到 prompt 就會換成短名。在那之前，`Peer.find`／`task add --to` 也認得「Chris-在做的事」開頭和看板記的英文名（不分大小寫）。只看活著的 session；兩個活的同名就報錯列出全名，不會亂送。**名字冷卻 3 天才回收**（`Nicknames.reuseAfter`）：session 結束後 Remote Control 會留一筆同名的離線紀錄，SendMessage 遇到兩個同名會退回要 ref（10-22 實測：新開的 Gavin 撞上 9 小時前的 Gavin）。`title` hook 每小時更新一次 `at`，當作「最後出現」，冷卻從這裡起算。
- **工作卡片自動轉送隊長（派工 T1021174030，ShoWorkCore/CardRelay.swift）**：任何 session 的 `showork card`（四種 status 都算）都由看板以【工作回報】Peer 直送給 `board/captain.json` 的隊長；內容含名字、專案、doing、狀態、完成度、信心、摘要、`--how`（這輪的方法與工具）、ask／options、報告、派工單號。隊長自己的卡不轉；隊長不在就不送也不堆積；同一 session 60 秒內只送一次（到時送最後一張）、內容沒變不重送；看板剛啟動時現有的卡不送；超過 10 分鐘的卡不送。只有正式 agent 送，設定 `captain.relayCards`（預設開）。
- **選項**：`showork card --ask "…" --options "A|B"`（最多 4 個、每個 40 字；沒有 --ask 不收）。AI 沒給選項就用通用的「好，照你的建議做／先不要，等我想一下」。
- **常駐隊長**：「交給隊長」找不到活著的隊長時，`BoardActions.askCaptain` 開 `claude --bg --model <captain.model，預設 claude-fable-5-1> -n 隊長 --permission-mode bypassPermissions`，第一句話是 `CaptainLaunch.bootstrap`（登記、守則、所有對使用者的話都走 showork card）。背景 session 也有收件匣，Peer 直送可以叫醒它（10-21 實測）。120 秒內不重開第二個。e2e：`ShoWorkAgent --board-act captain "<文字>"`。

## 電廠＝AI 額度（10-22）

- Kang 拍板：5 小時額度＝電力，用完公司停電；7 天額度＝油槽；原本代表 cool42 的冷卻塔搬上頂樓（右前方空地）。
- 資料：`CitySource` 每次 15 秒 tick 讀 `BoardStore.rateLimits()`（statusLine 存的 `~/.claude/cache/rate_limits.json`），`CityRules.grid` 轉成 `CityGrid`。重置時間已過算新的一輪（0%）。5 小時和 7 天取較高的一個決定階段：<80% 正常、80% 節電、95% 吃緊、100% 停電。
- 跨門檻才重畫：`CityRules.gridChanged` 只看階段、剩餘量換格（5% 一格）、重置時間換分鐘；城市內容鍵也只放這幾樣。
- 畫面：電廠門邊有電表（剩餘量、顏色依階段），屋頂有號誌燈（綠、黃、紅），名牌寫「5 小時剩 X%（HH:MM 重置）」，停電寫「HH:MM 復電」；油槽正面有液位窗；一條輸電線拉到大樓右側。
- 燈光（`OfficeBuilder.setGrid`）：燈、bloom 乘 1／0.6／0.35／0；補光乘 0.4＋0.6×乘數；所有發光材質走 `VoxMat.setPower`。停電時每層亮一盞綠色逃生燈，`HeatGate.setBlackout` 讓 AI 定格。號誌燈和逃生燈用不登記到發光清單的材質（`CityBuilder.signal`），停電時照樣亮。進入「吃緊」時閃 2 秒（一次性），之後維持穩定的暗度。
- 警示：吃緊以上列進「需要你」（`city:power`）；cool42 hot 以上改用 `city:cooler`。
- 測試：`SHOWORK_CITY_GRID=dim|flicker|blackout` 換成假數字（也適用於 `SHOWORK_CITY_DEMO`）。10-22 實測：螢幕外 1600×900 夜晚閒置 CPU，舊版 3.9%、新版 3.0%、停電 1.1%。

## 英文名與視窗標題（10-19）

Kang 分不出 `you-88`、`e1` 是誰，卡片標題又停在開場那件事，沒辦法戰情管控。改成每個 AI 一個英文名，卡片標題和終端機視窗標題都是「英文名-正在做的任務」。

- **取名**（`Nickname.swift`）：`brief`（SessionStart hook）時 `NicknameStore.ensure` 從 26 個名字（Alex…Zack，避開身邊真人的名字）挑一個活著的 session 沒在用的，存 `board/names/<sid>.json`；用完就加數字（Alex2）。session 結束後名字可以給新的 session。
- **任務**：`showork card --doing "<任務>"` 每輪更新，超過 24 字截斷。brief 要求 AI 每輪都帶，並告訴它自己的名字；跟使用者提其他 AI 時用英文名，對照表 `showork names`（英文名、SendMessage 地址、任務）。地址仍是 `you-xx`，英文名只是給人看的。
- **卡片標題**：`Board.build(nicknames:)` → `Nicknames.title`；還沒自報過任務就接原本的標題。
- **終端機視窗標題**：`showork title [--done]` 掛在三個 hook，前綴沿用 Claude 的符號（◐ 工作中、✳ 這輪做完），`TitleWatcher` 照樣認得。實測（2.1.29x）Claude Code 會一直重寫標題，所以三個時機各用不同方法：
  - `UserPromptSubmit`：回 `hookSpecificOutput.sessionTitle`（等同 `/rename`，transcript 會出現 custom-title）。這是唯一能讓「工作中」標題不被蓋掉的方法——Claude 轉 spinner 時是用它自己記的對話名稱重寫標題。副作用：`/resume` 清單也會顯示「Dora-待命」這類名字。
  - `PostToolUse(*)`：回頂層 `terminalSequence`（OSC 0）。會被下一格 spinner 蓋回去，只是補強。**PostToolUse 回 sessionTitle 沒有效果**，所以工作中途換任務，標題要等下一輪 UserPromptSubmit 才換（最多晚一輪）。
  - `Stop`：Claude 在 Stop 之後會把標題改回自己的，所以 fork `/bin/sh -c "sleep 1.5; printf OSC0 > $SW_TTY"`，tty 用 `TTYFinder.find()`。閒置時直接寫 tty 的標題不會再被覆蓋，閒置時一定是最新任務。
- **安裝器**：hook 清單在 `scripts/showork_install.py` 的 `our_hooks()` 和 `adapters/claude/hooks.py` 各一份，**兩邊都要改**；只改 hooks.py 時安裝器會顯示「already installed」而沒有加上去。

## 同 repo 多人（10-25）

同一個 repo 常有好幾個 session 同時在改（例：Ruby 做 3D、Sam 做收件匣），規矩跟防呆：
- commit 只 add 自己的檔、commit 前看 `git status`；別人還沒 commit 的改動讓主工作區編譯不過時，用 `git worktree add --detach <scratchpad>/… HEAD`，只複製自己的檔進去建置、測試、安裝。
- **安裝版本守門**（`scripts/showork_install.py`）：每次安裝把 commit 記到 `board/installed.json`（commit、dirty＝有沒有未提交改動、root＝從哪個資料夾、時間、forced）。要安裝的 HEAD 必須同時包含「已安裝的 commit」和「本機 main」（`git merge-base --is-ancestor`）：比已安裝的舊、在別的分支、或少了 main 上別人已經 commit 的東西 ⇒ 印原因、exit 3、不建置也不換執行檔。確定要退版才加 `--force`（照裝，紀錄 forced=true）。起因：Sam 從 d18a15b 的 worktree 安裝，差點蓋掉 Ruby 剛裝的電梯門等三個 commit。測試：`python3 -m unittest discover -s Tests/python`。

## 資料位置

`~/Library/Application Support/ShoWork42/`

| 檔案 | 用途 |
|---|---|
| `agent.sock` | CLI ↔ agent |
| `state.json` | 各 tty 狀態，agent 重啟後還原 |
| `agent.log` | `SHOWORK_DEBUG=1` 時的事件紀錄 |
| `bin/` | 安裝後的 `showork`、`ShoWorkAgent` |
| `board/` | 看板：`cards/` 自報、`reviews/` 審核、`decisions/`、`tasks/` 派工單、`names/` 英文名與任務、`captain.json`、`roster.json`、`history.jsonl` |
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
- **B1 留言板**（10-24）：B1 交流從「兩人同時在 B1 互傳一則」改成留言板。`B1Talk.pick` 一個人在 B1 休息就叫（一天 3 次、隔 60 分、5 小時額度 ≤60%、每人一天一次），叫他先 `showork b1 read` 再 `showork b1 post --text … [--re 編號]`。資料 `board/b1-board.jsonl`（一行一則 `B1Post`，只增不改；測試用 `SHOWORK_B1_BOARD` 換路徑）。每則同時以【B1 留言 #n】轉給現任隊長；隊長說明第 7 條要他整理成流程優化。
- **B1 收尾時順便留**（10-27 T1027193007）：不再叫醒 B1 閒置的 session（`B1Talk.pick` 與 BoardSource.b1Talk 已移除，閒置零花費）。改在 Stop hook `~/.claude/scripts/hook_ctx_wrapup.py` 的收尾提示裡，用 `showork b1 hint` 取 `B1Talk.wrapupNote` 插成第 ④ 步（收尾卡順延成 ⑤）：頂多一則可零則，沒有失敗、被糾正、重工就不留；只留需要修正的事（錯在哪、根因、建議規則、證據）；提示裡直接附板上最近 5 則（每則截 60 字，不多一次 b1 read），同一個坑就 `--re` 或不留。`b1-talks.json` 不再寫入。
- **隊長連動**（10-24，派工 T1024033803；規則 `ShoWorkCore/CaptainLink.swift`，沒有新增 hook，全掛在原本的 `showork title`（UserPromptSubmit）與 `showork guard-push`（PreToolUse Bash））：
  - ①開工卡：使用者直接下的指令（`CaptainLink.needsStart`：`<cross-session-message`／`<task-notification`／系統標籤開頭的不算）⇒ additionalContext 提醒動手前先發 `showork card --kind start --doing --summary --how --touch --outward`。距該 session 上一道使用者指令（`board/prompts/<sid>` 的 mtime）超過 10 分鐘＝完整提醒，10 分鐘內只提醒「換了任務才發」。隊長自己、cwd 含 `/ProjectC` 的 session 不提醒。轉隊長時 `CardRelay.text` 前綴【開工】，不受 60 秒節流；同一個 doing 10 分鐘內不重送。
  - ②動作預告：`board/guard/preview.tsv`（`類別<TAB>擋|告<TAB>正規表示式`，格式 v6；舊格式自動換成預設）。比對前 `CaptainLink.segments` 把指令切成一段段（引號外的 `; && || | & ( ) $(` 換行；去 sudo／env／VAR=值 前綴；heredoc 內文拿掉；引號內容換成 Q，ssh 那段保留；同一條指令裡設成暫存路徑的變數如 `T=$(mktemp -d)` 展開成 /tmp/），所以 `^` 就是指令的第一個詞。擋（rm 到暫存區以外、firebase deploy、App 上傳（-exportArchive／altool／notarytool／Transporter／fastlane）、line_send.py、GitHub 公開發言）⇒ deny＋單號、立即送隊長；GitHub 公開發言（10-24 隊長：Sam 在公開 repo 用 gh 留言／開 PR，開工卡回覆前就送出去了）＝`gh issue comment|create`、`gh pr create|comment|review`、`gh release create`、`gh api` 寫入 `repos/…`（-X POST／PATCH／PUT／DELETE，或帶 -f／-F／--input 這類預設成 POST 的欄位）；正規表示式只粗篩，命中後 `GHGuard.blockReason` 逐段看目標 repo（`-R`／`--repo`、參數裡的 github.com 網址、api 路徑的 owner/name；都沒有就是資料夾的每一個 remote，fork 的 PR 會開到上游所以上游也算；跟著 cd 走），全部是 Okle42 而且 `gh repo view --json isPrivate,owner` 回私有才免擋；別人的、公開的、gh 查不到或 8 秒沒回、路徑用變數 ⇒ 照擋，擋的原因附在預告摘要後面。api 只算 repos/ 路徑（graphql 等不算，照隊長給的範圍）。放行＝隊長 `showork release <單號>`（只限現任隊長）或使用者在那個 session 打「放行」「放行 <單號>」，30 分鐘內同一 session 同一指令（FNV 指紋）用一次，每次放行寫 `board/permits/releases.jsonl`（時間、單號、放行者、指令摘要、來源）。告（mv 到暫存區以外、xcodebuild archive 本機打包——10-31 Keng：可復原或不對外的改成只通知；defaults write、寫 ~/.claude/scripts|data、ssh winbox 寫入）⇒ 先進收件匣，看板把同一 session 安靜 5 秒（最多 30 秒）的合成一則送。隊長自己的指令不擋不告。`showork preview-check "<指令>"` 無副作用試算。限制：AI 技術上能偽造環境變數自己 release，只能靠規則與稽核紀錄；Write／Edit 工具不經過這個 hook。
  - ④隊長收件匣 `board/captain-inbox/<單號>.json`（start／notice／block；delivered、released、used、acked），7 天後刪。新隊長 `showork captain` 先印未處理的；`showork captain ack <單號｜all>` 標已處理。
  - ③⑤隊長鬧鐘：看板每 `captain.alarmMinutes`（預設 30）分鐘送【巡檢時間】（不含隊長的人數、各自 ctx、閒置超過 30 分鐘的人、收件匣未處理數）；指紋跟上次一樣只送「無變化」一行；沒有隊長不送；看板啟動起算。

## 本機私人設定 LocalConfig（10-27）

跟這台電腦、這個人有關的名字不寫進原始碼（repo 公開開發）。`~/Library/Application Support/ShoWork42/local.json`（不進 git；`SHOWORK_LOCAL_CONFIG` 換路徑）：`owner`（提示詞稱呼，預設「使用者」）、`headsetProjects`（戴耳機的專案）、`privateDataRepos`（data/ 一律擋 push）、`winHosts`（ssh 遠端 Windows 寫入要預告）、`noKickoffRepos`（不提醒開工卡）。沒有這個檔＝通用預設，功能照常。測試一律用 `LocalFixture`（假名），有沒有本機設定都要全過。
