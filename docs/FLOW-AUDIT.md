# 流量架構自檢（scripts/flow_audit.py）

11-22 建。每台電腦跑同一套檢查，兩台互當對照組；去掉隱私後把報告＋優化方向送回 Okle42 Discord「#自檢回報」集中收集。

## 檢查什麼
- **Claude 額度**：開著的 session 分類（互動／背景／Claude 預備程序／停放空殼／無頭呼叫）、各自閒置多久與記憶量（context）、
  今天的 token 與等效花費（依專案、主 session vs 子 agent）、快取命中率、每開一個 session 的開場 context、
  常駐設定重量（CLAUDE.md、記憶索引、MCP、hooks、外掛、技能）、額度與重置時間（有 ShoWork42 狀態列才有）
- **網路**：取樣 N 秒，網卡總進出、各程式進出量（Mac 用 nettop）、各程式連線數
- **建議**：依上面自動列出優化方向（空殼可關、大記憶量閒置該 /clear、快取命中低、子 agent 太多、開場太重⋯）

## 用法
```bash
python3 scripts/flow_audit.py --label 你的名字          # 跑一次：印報告、存 ~/.claude/flow-audit/*.json（去隱私版）
python3 scripts/flow_audit.py --set-webhook <網址>       # 第一次：設定回報網址（向 Keng 要；只存本機，不進 repo）
python3 scripts/flow_audit.py --label 你的名字 --send   # 跑完送到 #自檢回報
python3 scripts/flow_audit.py --compare A.json B.json   # 兩台並排比
```
只用 Python 標準庫；Mac 最完整，Windows／Linux 的網路那段是精簡版。只讀不改。

## 隱私（送出去的版本）
- 沒有對話內容、檔案路徑、電腦名稱、帳號、IP
- session 名 → S1、S2…；專案名 → 代號（P+雜湊）；程式名 → 類別（Claude／瀏覽器／通訊／同步／開發／系統／其他）
- `--names` 只讓本機那份保留專案名，送出去的一律去隱私
- 回報網址（Discord webhook）存在 `~/.claude/flow-audit/config.json`（權限 600），**不可以寫進 repo**（這個 repo 是公開的）
