# 球體助理（戰情中心第四個分頁）交接

最後更新：2026-11-22 下午（Bella，球體外圍量表、命名、背景 session 清理）
分支：`bella/sphere-tab`，worktree：`~/github-repos/_wt-ShoWork42-sphere`。已推 main（11-22 晚 Keng 指示「推 main」）。
本機已安裝：c4b5401（`board/installed.json`）。

## 檔案
- `windows/ShoWork.Win/Board/Web/sphere.html`：整個球體頁面（Mac WKWebView 和 Windows WebView2 共用）
- `Sources/ShoWorkAgent/SphereWebScene.swift`：Mac 宿主（資料推送、動作處理、聲音選單、`SphereWebView`）
- `Sources/ShoWorkAgent/SphereAudio.swift`：v5 播報引擎（AVAudioEngine＋vDSP FFT）
- `Sources/ShoWorkAgent/SphereMini.swift`：**球體桌面版**（11-22 起取代小球）、`DeskPanel`、`DeskChrome`（拖移／縮放）、`SphereListener`（按住講話的語音辨識＋麥克風頻譜）

## v5（11-22，參考 Keng 錄的 IG KARA 影片）
1. 狀態：中英雙標籤＋解碼動畫、思考掃描彗星、警示衝擊波
2. 事件卡：唸到誰就從球拉線彈出（`announce(text, {pop, banner})`）
3. 額度儀表：數字滾動、分段刻度、重置倒數、45 分鐘燒速預估（`localStorage sphere.hist5`）
4. 戰情卡：狀態色點、進度條、記憶量（payload team 多 `ctx`、`ago`）、狀態變就閃
5. 字幕逐詞同步：系統語音用 `write(toBufferCallback:toMarkerCallback:)` 的 marker（`byteSampleOffset / mBytesPerFrame` = 取樣位置）；微軟語音照播放進度比例
6. 警示橫幅：需要你（橘）、卡住／額度 ≥90%／過熱（紅）
- 聲波：`window.karaLevels({b:[32], r, p, d, mic})` 每 1/30 秒；（11-22 晚改）球外三條聲波絲帶＋字幕下平滑包絡；沒收到（Windows）就用假波形
- 背景：交叉點小十字（Keng 指定，不要整條網格線）

## 球體桌面版（11-22，T1122091602，Keng 選定的最終型態）
- 小球放大成完整球體：同一份 sphere.html 用 `?desk=1` 載入，功能跟分頁一樣（舊的 `?mini=1` 精簡模式已拿掉）
- 尺寸：小 460×620、中 540×720（預設）、大 1000×700；拖右下角自由縮放（最小 360×440）；工具列「尺寸」或選單列「桌面球體大小」切換；位置存 `sphere.mini.origin`、尺寸存 `sphere.desk.size`
- 拖移：上方 34px 標題列（網頁用 `deskChrome` 回報按鈕位置，那些地方不拖）；`SphereWebView.mouseDown` 攔
- 直式（≤640 寬）：球拉遠到 z=20、`setViewOffset` 往上移到 40% 高；卡片在下方；有人在等你時卡片讓位給選項面板（`body.asking`）
- 兩顆都開：自動播報（`announce(..., {auto:true})`）只有桌面版出聲，分頁那顆只出字幕
- 省電：桌面版一律 30 張／秒；解析度平常 2 倍、機器熱（paused）降 1 倍
- 測試：`--board-window` 加 `SHOWORK_TEST_SPHERE_MINI=1`（開在螢幕外）、`SHOWORK_TEST_DESK_SIZE={540,720}`、`SHOWORK_TEST_SPHERE_MINI_SHOT=<png>`、`SHOWORK_TEST_SPHERE_DESK_JS`、`SHOWORK_TEST_DESK_PROBE=1`（自動按一遍＋空白鍵 3 秒數嗶聲）

## 配色（11-22，Keng：黑白灰紅＋Okle42、42 用金色）
- CSS 色票在 `:root[data-theme=dark|light]`：`--acc` 紅（要注意＋少量點綴）、`--ink` 黑白、`--gray`／`--done` 灰、`--gold` 只給品牌的「42」
- 三維：`THEME3`（BALL／GRAY／ALERT／BAD／DONE）；淺色主題改 `NormalBlending`（相加混色在白底看不見），`applyTheme()` 換全部材質
- 工具列 ◐／●／○：自動（跟系統）→ 深 → 淺，存 `localStorage sphere.theme`，分頁和桌面版透過 storage 事件同步
- 品牌：分頁左上、桌面版標題列「OKLE42 · SHOWORK42」
- 測試：`window.karaTheme('light')`

## 版面與效能（11-22）
- 疊排 `body.stack`：`resize()` 算球直徑（≈5.49·h／z）放不放得下兩側卡片，放不下就球上移、卡片排下面、拉線垂直接卡片上緣；外環卡併進額度卡（#sysWrap）
- 效能：環形每圈併成 2 個物件、看不見的碎片／光暈／彗星／衝擊波不畫（draw call 230 → 40）；Retina 不開 MSAA；拿掉卡片毛玻璃；分頁閒置 30 張、有動作才 60；播完關 AVAudioEngine
- 實測（螢幕外，分頁＋桌面版同開）：平常 32% → 22% CPU、過熱模式 31% → 24%；`window.karaPerf()` 看每格毫秒與 draw call

## 面板拖移／縮放（11-22，Keng 不喜歡自動疊排）
- 字幕、額度、戰情、外環、選項面板（`PANELS`）都能拖、拉右下角調大小；記在 `localStorage sphere.layout.tab／desk`；視窗變小會夾回畫面內（至少留 60px）
- 分頁不再自動疊排（桌面版小／中仍預設疊排，拖過就照拖的位置）
- 位置記成錨點（`ah`／`av`）：離左／上 <20% 記距離、離右／下 <20% 記距離、中間記比例；調視窗大小、內容變高都會重擺，整片留在畫面內
- 拉線接卡片離球最近的那一邊（側邊水平、上下垂直）；卡片蓋在球上就不畫
- 滾輪（觸控板捏合）縮放球 0.45–2 倍，記在 `sphere.zoom.tab／desk`；工具列「重排」全部回預設
- 測試程式的 WKWebView 資料在 `~/Library/WebKit/ShoWorkAgent`，正式 App 在 `ai.okle42.showork.agent`，互不影響

## 自動排版（11-22，Keng）
- 工具列「自動排版」開關（預設開；沒存過版面就是開）。`autoLayout()` 每次依視窗大小與卡片內容高度算：寬＝左右兩欄、以球心水平線上下置中，球心移到工具列與底部狀態字之間的正中（`autoLift`→setViewOffset）；窄＝球上卡片下（`autoStack`）
- 開著時拖卡片＝改欄位（`layout.cols`，看放在左右半邊、在誰上面），放開吸附整理；滾輪＝`layout.zmul` 倍數；拉右下角調大小＝轉手動（`freezeAuto()` 照當下位置記成錨點）
- 上方字幕框拿掉：現況／逐詞字幕＋聲波移到底部狀態字下面（`#caption` 固定在底部，不在 PANELS）

## 拉線指向真資料（11-22，Keng：線不能隨便勾到球邊）
- 三個資料環（`gauge()`，在 `outer` 群組、面向鏡頭、半圓刻度：正下 0% → 卡片那側 → 正上 100%，卡片在右就鏡像 `gaugeSide`）
  - 額度：`g5`（5 小時，72 格，70/90% 門檻刻線，≥70 紅）、`g7`（7 天，80/95%）
  - 溫度：`gHeat`（35–100°C 一格 1 度，慢慢走到目前溫度、亮點沿著跑；55 以下灰→75 白→90 紅；hot／critical／≥92 閃爍＋衝擊波）
- （11-22 Keng 拿掉所有紅色指向線：`NO_LINES = true`，只留資料環尖端的點與數值；要恢復改成 false）
- 拉線每格更新（`linkFrame()`）：額度卡→5H 尖端、外環卡→溫度尖端、戰情卡→衛星（滑鼠所在列，否則 需要你＞卡住＞進行中）、事件卡→講到的東西；尖端有標籤（5H 31%、74°C、名字）
- 卡片位置只在事件時量（`drawLinks()` 存 `linkRect`），每格只投影目標點

## 面板開關與原子環（11-22）
- 額度／外環／戰情卡可關：卡片右上 ×、工具列「面板」選單（`.off`，存 `sphere.hide.tab／desk`）；關掉的卡不排版、不拉線；桌面版窄時早報／收工／時間軸收進這個選單
- 三個斜環（arcRing 有傾角的）外包 pivot，各自繞不同軸翻轉（`pivot.userData.axis／w`），像原子軌道；平的那圈不動

## 外圍量表（11-22 下午）
- 同心分層 `LAYER(k) = 2.96 + 0.1k`：由內到外 5H(0) → 7D(1) → 硬碟 1…4(2–5，右半邊 12 點→6 點，`dAng`) → 溫度(6，左半邊 6 點→12 點，`gAng`)；背景工作弧在最外圈
- 硬碟資料：原生端 `SphereDisks.read()`（內建＋/Volumes 可見、排除 Recovery），payload `disks:[{name, used, freeGB, totalGB}]`；外環卡多 DISK 列
- 顏色：每格照位置漸層 白→灰→黑→紅（`RAMP_AT` 0／0.4／0.7／0.85，`THEME3.ramp` 深淺主題各一組，深色的黑用深灰、淺色的白用淺灰）；警示波紋擴散時同一組漸層、最外圈紅後淡出
- 尖端：紅心黑圈準星＋標籤（名稱固定 ink、只有超標數字紅、一般粗細）；硬碟標籤放最外圈外側、太近錯開；`avoidCards()` 撞到卡片就翻邊／上下挪
- 點環或標籤：額度環→額度卡；溫度、硬碟環→外環卡；點衛星→戰情卡＋那一列閃
- 衛星：滑鼠指到的那顆停住，其他衛星與原子環減速到約 15%（`satSlow`、`s.slow`）；測試入口 `window.karaSats()`
- 配色多一檔 ☀ 日出日落（`sunTimes()` 台北座標本機算，每分鐘檢查）；測試 `window.karaSun(iso)`
- 工具列 `fitTools()`：不夠寬就 tight → tighter → tightest 逐級收

## 戰情中心：命名與背景 session（11-22 下午，動到 ShoWorkCore／showork CLI）
- 顯示名：有職稱用職稱（`showork role <職稱>`），沒有就「專案 · 任務」（家目錄只顯示任務）；英文名只當收件地址（`BoardCard.display／label`）
- 停放到背景（終端機 `parkedJobId` → 背景 `jobId`）：背景沿用終端機的英文名；空殼不上看板、不算活著
- Claude 背景常駐程式的預備程序（daemon.log `bg spawned <id> (spare)`：bg、沒名字、沒對話）不上看板
- `BgJanitor`：背景、從沒接過工作、閒置 10 分鐘 ⇒ `claude stop`（kill 會被重開）；做過事、/clear 過、比監看早出生、有自報卡都不動；記錄 `board/guard/bg-janitor.log`

## 流量架構自檢（11-22 晚，scripts/flow_audit.py，說明 docs/FLOW-AUDIT.md）
- Claude 額度＋網路自檢，去隱私（S1…、專案代號、程式類別）後 `--send` 送到 Okle42 Discord #自檢回報（私人頻道，id 1574003208366460988，在「文字頻道」類別）
- webhook 只存本機 `~/.claude/flow-audit/config.json`（600），不可進 repo；Okle42 Secretary 已加「管理 Webhooks」權限（Keng 授權、screen42 操作）
- 本機已實送兩次成功（附件 report.json／report.txt）
- **未完成／下一步**：①把 webhook 網址交給學弟（機爵）——Keng 還沒決定用機器人私訊或自己傳；②學弟跑 `--set-webhook` → `--label 學弟 --send`，拿兩份 JSON 用 `--compare` 對照；③若要自動彙整多台報告：機器人需開 Message Content intent 才讀得到附件
- 機器人讀不到別人訊息內容（沒開 Message Content intent），驗證送出要用 `--send` 的回傳（wait=true 會列附件）

## 終端機主題（11-22 晚）
- Ghostty 設定：~/Library/Application Support/com.mitchellh.ghostty/config.ghostty（原檔空的，備份 .bak-20261122）；主題檔 ~/.config/ghostty/themes/Okle42-Dark／Okle42-Light
  （舊位置 App Support/…/themes 還有一份重複副本，刪除被閘門擋 BS5HQ，等放行；不影響使用）
- 毛玻璃：background-opacity 0.72＋background-blur macos-glass-regular＋background-opacity-cells；**要 Ghostty 整個重開才生效**（會關掉所有 session，Keng 自己挑時機）
- 連動：球體配色鈕 → `GhosttyTheme.apply`（SphereWebScene.swift）改 config 的 theme 行＋點 Reload Configuration；
  只有 Claude Code 主題（**~/.claude/settings.json** 的 theme，不是 ~/.claude.json）是 light／auto、且主題改之前開的 session 都關了，才會切淺色（不然深色介面配淺底看不清楚）
- ~/.claude/settings.json：theme dark→auto；pluginConfigs prismantis options replyStyle／promptStyle／codeStyle=framed（備份 settings.json.bak-20261122-theme）

## KARA 對照改版（11-22 晚，完成）
- 錄影抽格：610×756、45 秒；KARA 的聲波不是放射條，是一束束髮絲細線繞球飄的綢帶（有殘影、會鼓起來）；三角是圓角描邊、部分填亮；外層有六角殼
- 球殼三角改圓角：每角二次貝茲 6 點（`CR=0.34`），約 24% 的面填亮（固定亂數）；**六角外殼拿掉**（Keng 不要）
- 聲波：120 根放射條拿掉，換成 `ribbons`（`RIB_N=3` 條 × `RIB_S=12` 根細線 × `RIB_P=160` 點，頂點色帶透明度，一條一個 draw call）
  - 比 KARA 好的地方：真頻譜驅動、三條各吃低／中／高頻（`lo/hi`）、細線＝波形歷史（`hist` 環，每根落後 2 格）＝殘影、沿角度扭轉像綢帶翻面、被推出去的地方變亮（深色往白、淺色往黑）
  - 沒聲音時剩淡淡呼吸（`ribLevel`）；聆聽時灰色
- 字幕下波形：方塊條改平滑上下對稱包絡（漸層填色）＋三根相位錯開細線、兩端淡出
- 驗證：螢幕外桌面版 540×720、1000×700、淺色主題各截一張（假頻譜＋karaSay），絲帶與圓角都看得到；**Keng 還沒實機看**
- 測試指令：`SHOWORK_WEB_DIR=$PWD/windows/ShoWork.Win/Board/Web SHOWORK_TEST_SPHERE_MINI=1 SHOWORK_TEST_DESK_SIZE='{1000,700}' SHOWORK_TEST_SPHERE_MINI_SHOT=<png> SHOWORK_TEST_SPHERE_DESK_JS='<假頻譜 setInterval＋karaSay>' perl -e 'alarm 24; exec @ARGV' .build/debug/ShoWorkAgent --board-window`（本機沒有 timeout 指令，用 perl alarm）

## prismantis 內化（11-22 晚，完成）
- mod 在 `mods/okle42/`（fork 自 prismantis 0.46.0，MIT，LICENSE／THIRD_PARTY_NOTICES 保留，說明在 mods/okle42/README.md）；repo 根 `.claude-plugin/marketplace.json`（marketplace 名 showork42）
- 改名：外掛 okle42、指令 `/okle42`、`$.okle42`、事件 `okle42.markdown`、設定 `pluginConfigs["okle42@showork42"]`
- 配色：新增 `okle42` 色票（預設），全用 ANSI 色名（red／white／whiteBright／blackBright），靠 Ghostty Okle42-Dark／Light 的 palette 自動跟深淺；回覆／提問／程式碼預設 framed；issueHint 預設關
- 本機：`claude plugin marketplace add`（目前指向這個 worktree 路徑，directory 來源＝直接從資料夾載入，改檔就生效）＋`install okle42@showork42`；**prismantis@prismantis 已停用**（沒刪）；備份 ~/.claude/settings.json.bak-20261122-okle42
- 驗證：`claude plugin validate mods/okle42` 通過；新 session（claude -p --debug-file）確認 okle42 載入、/okle42 註冊、prismantis 不註冊。**畫面效果要 Keng 開新終端機 session 看**
- 回退：`claude plugin enable prismantis@prismantis && claude plugin disable okle42@showork42`
- 待辦：worktree 收掉前要把 marketplace 改指 ~/github-repos/ShoWork42（`claude plugin marketplace remove showork42` 再 add 主 repo 路徑）

## 聲波改粒子（11-22 晚，完成；Keng 從戰情中心選「你自己設計粒子版」）
- 絲帶線條 → 星塵帶：三條 `THREE.Points`（`RIB_PN=1800` 顆／條，圓形柔邊貼圖 `dotTex`，頂點色帶透明度），軌道面同原本
- 粒子固定屬性：起始角、帶上位置（近似高斯）、落後格數（偏新）、流速（三條方向不同、講話時流快）、18% 是火花（有聲音才往外噴、邊飛邊淡）
- 截圖：深色、淺色都看得到；效能 2400 顆時每格 JS 5.4ms（30 張），降到 1800；Keng 還沒實機看
- 上面「KARA 對照改版」講的線條絲帶已被這版取代
- 配色（Keng 追加）：粒子走量表同一組 白→灰→黑→紅 漸層（`rampLut()` 64 格查表，主題換才重算）；漸層位置＝音量推出去的程度＋落後格數，火花一路飛到紅；聆聽時灰色。實測每格 JS 3.2ms

## 自檢原子環（11-22 晚，Keng：要的是「流量檢查優化報告」，不是用量——用量已有左邊 5H／7D 半圓表）
- 最內側斜環（arcRing 2.15，加 `custom` 參數）改成自檢環：7 段等長 `AUDIT_KEYS` 快取／開場／閒置／空殼／子agent／常駐／網路；
  `auditScores()` 0＝健康→1＝該優化（門檻對齊 flow_audit.py advice()，到門檻≈0.85＝紅），顏色走 `rampColor`；沒跑過＝暗灰
- 外環卡多「AUDIT」區塊：時間、N 項待優化、7 項圓點、前 3 條建議（單行、滑過看全文）、按鈕「重跑」「送 #自檢回報」；額度那條建議不放；#cardSys 改可捲
- 點自檢環 → 外環卡（gaugeAt 加 auditRing.mesh）
- 何時跑（Keng 選「開工／收工各跑一次」）：早報時段（5–11 點）、收工時段（19 點後）每天各一次（localStorage sphere.audit.am／pm）；按「早報」「收工」鈕也會跑
- 原生端 `SphereAudit`（SphereWebScene.swift）：背景跑 `python3 -I flow_audit.py --label Keng --names --out ~/.claude/flow-audit/sphere [--send]`（約 20 秒，含網路取樣 10 秒），輸出寫 last.log；payload `audit`（at、today、standing、sessions、net、advice）＋`auditBusy`
- 安裝腳本把 scripts/flow_audit.py 複製進 App 包 Resources；送出（--send）一律去隱私
- 「處理 N 項」鈕（Keng 選「加，直接處理」）：原生 `SphereAudit.fix()` 重讀 ~/.claude/sessions，只動不丟對話的兩種——停放空殼（parkedJobId 指向活的背景 job）送 SIGTERM、預備程序（bg、沒名字、沒講過話）`claude stop`；做完重跑自檢；記錄 ~/.claude/flow-audit/sphere/fix.log；閒置大記憶量／常駐設定不動。**沒實按過**（按了會真的關程序）
- 驗證：螢幕外桌面版 1000×860 深／淺色截圖，環 7 段有上色、卡片區塊正常；重跑／送出按鈕沒實按過
- 11-22 Keng：「N 項待優化」只算紅的（≥0.85，跟 flow_audit.py 出建議的門檻一致）；0.6–0.85 標「◐ 注意」，沒有紅的時顯示「N 項注意」
- 同日依自檢建議精簡 MEMORY.md：214 行／6952 token → 97 行／3367 token（專案分 10 個總表 hub_*.md、已結束的進 hub_封存.md，原記憶檔都沒刪；備份 ~/.claude/projects/-Users-hairllypoter/memory.bak-20261122-slim）

## 字幕跟語音（11-22）
- 開語音時 `say(..., follow=true)`：不先打字，等原生報「唸到哪」才出字（Mac：逐詞 marker＋合成完算出總長後的播放進度；微軟：播放進度）；`karaVoice('start')` 後 1.2 秒沒同步才退回照速度打字

## 坑
- **tap 在 mainMixer 輸出端**：`outputVolume` 會影響量到的頻譜（測試設 0 會量到全 0，不是壞掉）
- 頻譜正規化 `(dB + 18) / 56`：用曉臻 mp3 校正，中位數約 0.3
- 按住空白鍵：自動重複鍵沒人收 macOS 會每下嗶一聲（c4b5401 修好：網頁吞＋`SphereWebView` 原生丟掉 isARepeat）
- 測 WKWebView 鍵盤：螢幕外視窗要覆寫 `isKeyWindow`，不能 activate 搶 Keng 焦點；`noResponder(for:)` 計數＝嗶聲數；http 載入記得加 `?v=` 避快取
- 安裝腳本只認 commit 祖先關係：分支 rebase 過要先 `git range-diff` 確認內容都在，才用 `--force`

## 還沒驗 / 下一步
- Keng 實機試聽 v5 與空白鍵修正（等他回饋：聲波大小、字幕節奏、橫幅會不會太吵）
- Windows（WebView2＋SAPI）沒有真機驗過，沒有真頻譜（用假波形）
- 曉臻沒有逐詞 marker，字幕照進度比例，可能差半拍
