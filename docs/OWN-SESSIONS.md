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

## 11-08 收尾實測（真 claude、haiku）

- `/compact`：id 不變，串流出 `system/compact_boundary`，壓縮後還記得前文。
- `/clear`：串流出 `conversation_reset`，再出新的 `init`，**session id 會換成新的**。
  SessionHost 的把手固定用原本的 id，新的記在 `OwnedRecord.currentId`；接回、權限、看板、終端機指令一律用 `liveId`。
- 權限：原本 `showork` 的 hooks 會把所有 `sdk-*`（claude -p）都當成審核員直接略過，所以權限不會進收件匣，在 -p 模式下等於直接被拒。
  修法：SessionHost 啟動時帶 `SHOWORK_OWNED=1`，hooks 看到就照常處理。
  實測用真的 `showork permit` 加上隔離的 home（`CFFIXED_USER_HOME`），結果：允許時檔案寫成、拒絕時沒寫、真的收件匣沒被碰到。

## 11-08 交接（Bella → 下一棒）

已在分支 board/own-sessions（本機，未 push）：H1、H2、H3（Alex）、/clear 換 id、hooks 放行（SHOWORK_OWNED）、H4（6b5bc0f）。swift test 264 項全過。

下一步（使用者要求「能完成的全部完成，再開給他用」）：
1. **等 Alex 的 H5**（3D 辦公室改版：大樓換單層開放辦公室、Mac 改 WKWebView 載共用 three.js、城市與 B1 保留、點角色開工作視窗）。Alex 做完會傳訊息，收到要先核對（swift test、螢幕外截圖、私人字掃描）。
2. **整合安裝**：`scripts/showork_install.py`。裝之前先確認 Alex 沒在改同一個檔。
3. **裝好後的實測**（交給使用者之前要做的）：
   - 新任務從頭到完成全程不碰終端機：工作視窗送話、看工具過程、權限卡允許／拒絕、中斷、/compact。
   - 交給隊長：會開一個 Opus 隊長，先告訴使用者會用到額度。
   - 交棒到 Ghostty：會在使用者螢幕開視窗，要先問。
4. **還沒做、這台 Mac 上做不了**：Windows WebView2 宿主（Surface 由 Gavin 主導）。

已知邊角：
- /clear 之後 CaptainStore 記的還是把手 id，看板「誰是隊長」的判斷可能對不上。
- H4 的 BoardActions 改動沒有自動測試（ShoWorkAgent 這個 target 沒有測試）。

## 11-08 H5 完成（Alex）

- 網頁端（d78af03、f5e8182）：`windows/ShoWork.Win/Board/Web/scene/openoffice.js`（`OpenOfficeBuilder extends OfficeBuilder`，只換大樓那一塊；城市、B1、燈光、天氣、名牌照舊）。
  - 格局：跟原大樓同一塊地，人和家具縮成 0.68 倍。工位格子 8 欄 × 4 排，每個專案佔整欄（工作中／等你／卡住才坐桌子），用到的欄置中；
    隊長在會議室、閒置／睡著在休息區、做完在茶水間、保全在前台（不巡邏）；位子不夠站前排走道。區域名稱貼在地上。
  - 上方分頁（3D 區域左上）：總覽／走進去（第一人稱：拖曳轉頭、WASD 走、滾輪前後、Esc 回總覽）＋各區。
  - 家具：Kenney Furniture Kit（CC0），載入後換成 VoxMat 純色材質、同材質合併；授權記在 `Web/assets/README.md`。GLTFLoader 是 three r170 官方 examples（MIT）。
  - 左側索引列還是舊的大樓樓層名（點下去會飛到對應的區），沒改。
- Mac 端（faca5ca，子代理）：`Sources/ShoWorkAgent/OfficeWebHost.swift`（WKWebView＋`showork://` scheme＋office2 推送＋全部動作接線），
  `BoardWindow` 改用 `OfficeWebScene`；`SHOWORK_OFFICE_LEGACY=1` 退回 SceneKit 大樓。安裝腳本把整份 Web 資料夾（排除 bench、.md）放進 Resources/Web。
- 驗證：`ShoWorkAgent --office-web-snap <png> [demo]`（螢幕外、測試時動作不送出），真資料與 demo 都畫得出來、沒有 JS 錯誤；swift test 264 項全過。
- **SceneKit 舊程式（OfficeView／OfficeBuilder／OfficeTower／OfficeCity／OfficeBasement／OfficeVoxel…）還沒刪**：等使用者實際用過 Web 版、確定能取代再刪（目前是退回路線）。

## 3D 物件清單（11-08 H5 第三版；自製素材照這份做）

規則（`Web/scene/props.js` 開頭也有寫）：
- 每種物件一個檔，放 `windows/ShoWork.Win/Board/Web/assets/models/<名稱>.glb`，再把檔名加進同資料夾的 `manifest.json`（`{"models": ["desk.glb", …]}`）就會換上；沒列的用程式畫的佔位方塊。
- 單位公尺、Y 朝上、正面朝 +Z（人坐的那側／面向使用者的那面），原點在底面中心。載入後等比例縮到塞進下表尺寸、貼地置中；材質用模型自己的。
- 人物 `person_base.glb`：約 1.72 公尺高，要帶動畫 `idle`、`walk`、`sit`（名稱含這三個字即可），坐姿時臀部約在原點上 0.45。不同人用同一個模型（之後可再分髮型、衣服）。
- 房間是用「人的公尺」排的（整層 24 × 19.6），整棟縮 0.5 倍放進原本大樓那塊地；模型照真實尺寸做就好。

| 檔名 | 尺寸（寬×高×深，公尺） | 放在哪一區 | 說明 |
|---|---|---|---|
| `person_base.glb` | 0.5 × 1.72 × 0.3 | 各區（AI 人物、保全） | 人物，帶 idle／walk／sit 動畫 |
| `desk.glb` | 1.4 × 0.75 × 0.7 | 工作區 | 單人辦公桌 |
| `desk_divider.glb` | 1.4 × 0.45 × 0.04 | 工作區 | 桌上隔板（布面） |
| `chair_office.glb` | 0.6 × 1.05 × 0.6 | 工作區 | 辦公椅（滾輪） |
| `monitor_dual.glb` | 1.05 × 0.48 × 0.22 | 工作區 | 雙螢幕（螢幕面發光，顏色＝狀態） |
| `keyboard.glb` | 0.45 × 0.03 × 0.15 | 工作區 | 鍵盤 |
| `mug.glb` | 0.09 × 0.1 × 0.09 | 工作區、茶水間 | 馬克杯 |
| `documents.glb` | 0.3 × 0.05 × 0.22 | 工作區 | 一疊文件 |
| `desk_lamp.glb` | 0.2 × 0.45 × 0.2 | 工作區 | 檯燈（燈罩發暖光） |
| `cork_board.glb` | 1.2 × 0.9 × 0.04 | 工作區 | 軟木公佈欄（掛牆） |
| `poster.glb` | 0.6 × 0.85 × 0.02 | 工作區、走道 | 海報（掛牆） |
| `meeting_table.glb` | 4.0 × 0.75 × 1.3 | 會議室 | 長會議桌 |
| `chair_meeting.glb` | 0.55 × 0.95 × 0.55 | 會議室 | 會議椅 |
| `projector_screen.glb` | 2.4 × 1.6 × 0.06 | 會議室 | 投影幕（掛後牆，畫面發光） |
| `whiteboard.glb` | 1.8 × 1.1 × 0.05 | 會議室 | 白板（掛側牆） |
| `exec_desk.glb` | 1.9 × 0.78 × 0.9 | 主管室 | 主管大桌 |
| `chair_exec.glb` | 0.7 × 1.25 × 0.7 | 主管室 | 主管椅（高背皮椅） |
| `bookshelf.glb` | 1.2 × 2.0 × 0.4 | 主管室、工作區 | 書櫃（滿書） |
| `trophy.glb` | 0.2 × 0.35 × 0.2 | 主管室 | 獎盃 |
| `globe.glb` | 0.4 × 0.55 × 0.4 | 主管室 | 地球儀 |
| `chart_board.glb` | 0.8 × 1.6 × 0.5 | 主管室 | 圖表看板（畫架） |
| `pool_table.glb` | 2.5 × 0.85 × 1.4 | 休息區 | 撞球桌 |
| `foosball.glb` | 1.4 × 0.95 × 0.75 | 休息區 | 手足球台 |
| `beanbag.glb` | 0.9 × 0.7 × 0.9 | 休息區 | 懶骨頭 |
| `sofa.glb` | 2.2 × 0.85 × 0.9 | 休息區 | 三人沙發 |
| `armchair.glb` | 0.9 × 0.85 × 0.85 | 休息區 | 單人沙發椅 |
| `rug_large.glb` | 3.2 × 0.02 × 2.2 | 休息區、主管室 | 大地毯 |
| `tv_wall.glb` | 1.8 × 1.05 × 0.08 | 休息區 | 壁掛電視 |
| `coffee_table.glb` | 1.1 × 0.42 × 0.6 | 休息區 | 茶几 |
| `kitchen_counter.glb` | 3.0 × 0.92 × 0.65 | 茶水間 | 靠牆流理台（含上櫃） |
| `kitchen_island.glb` | 2.2 × 0.95 × 0.9 | 茶水間 | 中島 |
| `bar_stool.glb` | 0.4 × 0.75 × 0.4 | 茶水間 | 高腳椅 |
| `fridge.glb` | 0.8 × 1.9 × 0.7 | 茶水間 | 冰箱 |
| `vending_machine.glb` | 1.0 × 1.9 × 0.8 | 茶水間 | 販賣機（前面發光） |
| `water_dispenser.glb` | 0.35 × 1.3 × 0.35 | 茶水間 | 飲水機 |
| `toilet_stall.glb` | 1.0 × 2.0 × 1.5 | 廁所 | 廁所隔間（含馬桶） |
| `sink_counter.glb` | 1.6 × 0.9 × 0.55 | 廁所 | 洗手台＋鏡子 |
| `plant_tall.glb` | 0.6 × 1.6 × 0.6 | 各區 | 大盆栽 |
| `plant_small.glb` | 0.3 × 0.45 × 0.3 | 各區（桌上、櫃上） | 小盆栽 |
| `floor_fan.glb` | 0.45 × 1.3 × 0.35 | 工作區、休息區 | 落地扇 |
| `pendant_lamp.glb` | 0.5 × 0.9 × 0.5 | 各區（天花板吊下） | 吊燈（燈罩發暖光；原點在燈罩底） |
| `trash_bin.glb` | 0.3 × 0.45 × 0.3 | 各區 | 垃圾桶 |
| `reception_desk.glb` | 2.6 × 1.1 × 0.8 | 前台 | 前台櫃台 |
| `door.glb` | 1.0 × 2.2 × 0.08 | 各房間 | 室內門（玻璃門片） |
| `tree.glb` | 2.0 × 4.0 × 2.0 | 戶外 | 樹 |
| `bush.glb` | 1.0 × 0.7 × 1.0 | 戶外 | 灌木 |
| `street_lamp.glb` | 0.4 × 3.6 × 0.4 | 戶外 | 路燈（燈頭發暖光） |
| `bench.glb` | 1.6 × 0.85 × 0.6 | 戶外 | 長椅 |

程式自己畫、不用模型的：地板（木地板、深色木地板、磁磚、淺磁磚、棋盤磚、藍地毯、紅地毯）、牆、窗、百葉、玻璃隔間、門牌、區域名稱、草地、步道、接觸陰影、狀態光圈與寶石、螢幕發光、保全的監控螢幕。

## 11-08 H5 第三版（Alex）

- 使用者看了第二版說「太陽春」，標準拉到跟 IG demo 並排不輸；素材決定自己做一套（不用外部素材包，Kenney 已拿掉）。
- 這版做的（素材以外）：一層拆成會議室（隊長）、主管室、茶水間（做完的）、廁所、走道、工作區（每專案一區、每人一張桌：桌、隔板、雙螢幕、鍵盤、椅子、文件、馬克杯、檯燈）、
  休息區（閒著的：撞球、手足球、沙發、懶骨頭、電視）、前台（保全）；地板分區（木地板、地毯、磁磚、棋盤磚）、窗＋百葉、玻璃隔間、門、門牌（TOILETS 廁所…）；
  太陽陰影（PCF soft）＋家具接觸陰影（假 AO）＋室內暖色點光與吊燈（夜裡比較亮）；外圍草地、樹、灌木、路燈；名牌人多只寫名字；左側索引列改區域（含 B1、城市）。
- 人：`scene/person.js` 程式人物（有臉、髮型、衣服依 id 固定；待機、坐著打字、走路動畫），換位置時沿走道走過去。`person_base.glb` 載得到就改用模型。
- 物件：`scene/props.js` 註冊表＋佔位畫法，清單見上方「3D 物件清單」。
- 比較圖：`~/Desktop/ShoWork42_3D參考/H5_第三版_比較.png`（左 IG demo、右第三版，總覽＋走進去工作區／休息區／茶水間）。
- **安裝中的版本還是第二版（bf411ec，Kenney 人物）**：等使用者看過第三版說可以才重裝。
- 端對端實測（真 haiku，`ShoWorkAgent --work-e2e`）：送話、看工具過程、權限卡允許／拒絕、中斷都 OK；/compact 這輪沒等到 compact_boundary。
  發現：戰情中心持有的 session 會照使用者的全域 hook 每輪跑 `showork card`，預設權限下每次都要按允許 ⇒ 建議 SessionHost 啟動時把這個指令列進允許清單（還沒改）。
