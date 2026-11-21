# 球體助理（戰情中心第四個分頁）交接

最後更新：2026-11-22（Bella）
分支：`bella/sphere-tab`，worktree：`~/github-repos/_wt-ShoWork42-sphere`。**沒有 push**（push 要 Keng／隊長轉述核可）。
本機已安裝：c4b5401（`board/installed.json`）。

## 檔案
- `windows/ShoWork.Win/Board/Web/sphere.html`：整個球體頁面（Mac WKWebView 和 Windows WebView2 共用）
- `Sources/ShoWorkAgent/SphereWebScene.swift`：Mac 宿主（資料推送、動作處理、聲音選單、`SphereWebView`）
- `Sources/ShoWorkAgent/SphereAudio.swift`：v5 播報引擎（AVAudioEngine＋vDSP FFT）
- `Sources/ShoWorkAgent/SphereMini.swift`：桌面小球、`SphereListener`（按住講話的語音辨識＋麥克風頻譜）

## v5（11-22，參考 Keng 錄的 IG KARA 影片）
1. 狀態：中英雙標籤＋解碼動畫、思考掃描彗星、警示衝擊波
2. 事件卡：唸到誰就從球拉線彈出（`announce(text, {pop, banner})`）
3. 額度儀表：數字滾動、分段刻度、重置倒數、45 分鐘燒速預估（`localStorage sphere.hist5`）
4. 戰情卡：狀態色點、進度條、記憶量（payload team 多 `ctx`、`ago`）、狀態變就閃
5. 字幕逐詞同步：系統語音用 `write(toBufferCallback:toMarkerCallback:)` 的 marker（`byteSampleOffset / mBytesPerFrame` = 取樣位置）；微軟語音照播放進度比例
6. 警示橫幅：需要你（橘）、卡住／額度 ≥90%／過熱（紅）
- 聲波：`window.karaLevels({b:[32], r, p, d, mic})` 每 1/30 秒；球外圈 120 根放射條＋字幕下波形；沒收到（Windows）就用假波形
- 背景：交叉點小十字（Keng 指定，不要整條網格線）

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
