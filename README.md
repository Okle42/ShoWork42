# ShoWork42

> 終端機裡的 AI 在工作、做完了、在等你回答——不用切過去看，視窗外圍的光就告訴你。

macOS 常駐小工具。每個跑著 AI（Claude Code、Codex、Gemini⋯⋯）的終端機視窗，依 AI 當下狀態在外圍發光：

| 狀態 | 顏色（預設） | 什麼時候 | 什麼時候消失 |
|---|---|---|---|
| 工作中 | 紫 · 呼吸 | 送出指令、執行工具 | 做完或等你 |
| 已完成 | 綠 `#30D158` | AI 回合結束 | 你在該視窗**按鍵或點擊** |
| 等你回答 | 紅 | 權限詢問、提問 | AI 繼續往下走 |

一個視窗有多個分頁時取最需要注意的：**紅 > 綠 > 紫**。

> 狀態：**開發中、私人 repo**。M0（技術驗證）完成，M1（Claude Code × Ghostty 日用）進行中。公開前要完成簽章＋公證＋全矩陣實測。

## 功能

- **三種終端機**：Ghostty（含 tmux）、Terminal.app、iTerm2 —— 背景分頁、多視窗、tmux 多 client 都對得到。
- **光暈**：點擊穿透、跟著視窗移動／縮放／疊放；全螢幕改畫螢幕邊緣 3pt 細光；「減少動態效果」時不動畫。
- **設定視窗**（選單列 → 設定⋯ ⌘,）：三種狀態各自調開關、顏色、六種光芒款式（呼吸／流光繞行／漣漪外擴／光霧飄動／微光粒子／極光旋轉）、亮度、寬度、速度，即時預覽。
- **自動排版**（可關）：終端機視窗數量變動時自動排；⌃⌥L 立即排。1–11 個視窗各有固定排法，6 個以上重疊排並自動整理疊放順序。
- **選單列總覽**：● 數量，點清單直接跳到該視窗。
- **後備偵測**：沒讀到 hooks 的舊 Claude session，改讀 Ghostty 分頁標題的轉圈符號判斷狀態。

## 設計原則（硬規矩）

1. **絕不拖累 AI**：hook 呼叫的 `showork emit` 最多 200 ms、永遠 exit 0、不讀 stdin。
2. **不連網**：只用本機 Unix socket（權限 0600）。
3. **與其他工具的 hooks 共存**：安裝只「合併」自己的 hook 群組，寫入前備份，移除只拿掉自己的。
4. **光暈永遠點擊穿透**，不搶焦點、無 Dock 圖示。
5. **不碰使用者視窗標題**：Ghostty 對應用 OSC 7 探針，用完寫回原 cwd。

## 安裝

需求：macOS 14+、Swift 6 工具鏈。

```sh
python3 scripts/showork_install.py install     # 編譯 release、簽章、裝 LaunchAgent、合併 Claude hooks
python3 scripts/showork_install.py status
python3 scripts/showork_install.py uninstall   # 移除 agent 與自己的 hooks
```

- 首次啟動會請求「輔助使用」權限（系統設定 → 隱私權與安全性 → 輔助使用 → ShoWorkAgent），授權後自動重啟接手。
- 有 Apple Development／Developer ID 憑證時用它簽章，重新編譯後權限不會失效；沒有就 ad-hoc。
- 只想看 hooks 片段不安裝：`python3 adapters/claude/hooks.py /path/to/showork`

## 開發

```sh
swift build
swift test                       # ShoWorkCore 單元測試（狀態機、排版幾何、標題訊號）
Tests/e2e/resolver_e2e.sh        # tty → 視窗對應（會開測試用終端機視窗）
Tests/e2e/engine_e2e.sh          # 事件 → 光暈
Tests/e2e/layout_e2e.sh          # 排版（白名單保護，見下）
```

⚠ e2e 會開關真實視窗。排版測試一律帶白名單 `SHOWORK_ONLY_WIDS`，畫面上出現名單外視窗就整個中止；驗證防護時加 `SHOWORK_ARRANGE_NOOP=1`（只檢查不搬）。

除錯：`SHOWORK_DEBUG=1 python3 scripts/showork_install.py install` 後，`~/Library/Application Support/ShoWork42/agent.log` 會記 EVT／ACK／REAP／RESTORE／TITLE。

## 文件

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — 架構、資料流、各模組職責、已知坑
- [docs/M0-進度.md](docs/M0-進度.md) — 技術驗證紀錄（對應法、壓力測試數據）
- [docs/M1-計畫.md](docs/M1-計畫.md) · [docs/M1b-排版計畫.md](docs/M1b-排版計畫.md) — 目前里程碑
- [docs/decisions/](docs/decisions/) — 規格拍板用的決策板（HTML）與答案

## 路線圖

| 里程碑 | 內容 | 狀態 |
|---|---|---|
| M0 | 視窗對應＋光暈跟隨／疊放（三種終端機、tmux、切桌面、全螢幕） | ✅ |
| M1 | Claude Code × Ghostty 日用一天零誤報；排版；設定視窗 | 進行中 |
| M2 | Codex、Gemini、通用後備（看輸出動靜） | |
| M3 | Terminal.app、iTerm2 日用驗收 | |
| M4 | 打包、簽章＋公證、README GIF、公開 | |

---

© Okle42
