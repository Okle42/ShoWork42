# 球體助理（戰情中心第四個分頁）交接

最後更新：2026-11-22（Bella，球體桌面版）
分支：`bella/sphere-tab`，worktree：`~/github-repos/_wt-ShoWork42-sphere`。**沒有 push**（push 要 Keng／隊長轉述核可）。
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
- 聲波：`window.karaLevels({b:[32], r, p, d, mic})` 每 1/30 秒；球外圈 120 根放射條＋字幕下波形；沒收到（Windows）就用假波形
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
