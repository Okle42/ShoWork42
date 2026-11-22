# okle42（Claude Code 回覆樣式 mod）

ShoWork42／Okle42 自己的 Claude Code 回覆樣式：黑白灰紅，跟 Ghostty 的 Okle42-Dark／Okle42-Light 主題同色票。

- **來源**：fork 自 [prismantis](https://github.com/NahumLitvin/prismantis) 0.46.0（Nahum Litvin，MIT），原 LICENSE 與 THIRD_PARTY_NOTICES.md 保留在此資料夾。
- **改了什麼**：外掛名 prismantis → okle42（指令 `/okle42`、`$.okle42`、事件 `okle42.markdown`、設定鍵 `okle42.*`）；
  新增 `okle42` 色票並設為預設——全部用終端機 ANSI 色名（red／white／whiteBright／blackBright），終端機切深淺時自動跟著換；
  回覆、提問、程式碼預設 `framed`（透明框、不填底色）；預設不提示模型去原作者 repo 開 issue。
- **安裝**（repo 根目錄有 `.claude-plugin/marketplace.json`）：

```bash
claude plugin marketplace add ~/github-repos/ShoWork42
claude plugin install okle42@showork42
```

- **檢查**：`claude plugin validate mods/okle42`
