// OfficeView.swift 的 OfficeDemo（示範資料）照搬（11-02 P8）：office.html?demo=1 的隊長對話、派工單、右側對話窗格、保全假狀態。
// 名字、專案、MAC、IP 全是假的（192.0.2.x 是文件用的保留網段、02: 開頭是本地管理的 MAC）。
// 大樓、人物、城市的示範資料不在這裡：直接讀 bench/mac-input.json（Mac SHOWORK_OFFICE_DEMO=all dump 出來的那份）。

const now = () => Date.now() / 1000;
const L = (id, at, role, text, via = null) => ({ id, at, role, text, via });

export const OfficeDemo = {
  /** 示範的右側對話窗格（10-25）：一般 AI 的對話，含中途的話與工具摘要 */
  personThread() {
    const t = now() - 600;
    return [
      L("p1", t, "kang", "幫我把登入頁的錯誤訊息改成中文", "戰情中心"),
      L("p2", t + 20, "captain", "好，我先找登入頁在哪。"),
      L("p3", t + 25, "tool", "搜尋檔案"),
      L("p4", t + 30, "tool", "讀檔：LoginView.swift"),
      L("p5", t + 60, "tool", "修改：LoginView.swift"),
      L("p6", t + 80, "tool", "執行指令：跑單元測試"),
      L("p7", t + 120, "captain", "改好了：3 個錯誤訊息都換成中文，**測試 12 個全過**。要順便改註冊頁嗎？"),
    ];
  },

  /** 示範的隊長對話與派工單 */
  captainThread() {
    const t = now();
    return [
      L("d1", t - 1500, "kang", "把 ProjectD 的設定頁做完，匯出功能一起做", "戰情中心"),
      L("d2", t - 1480, "captain", "收到，兩條線並行：\n- **Dora** 繼續 ProjectD 設定頁\n- 匯出功能我開 workflow，三個決策已發到收件匣，你拍板就開工"),
      L("d3", t - 900, "report", "【工作回報】Dora（ProjectD）：設定頁 完成度 92%", "AI工作戰情中心"),
      L("d4", t - 600, "report", "【派工回報 T1022020414】Ethan：完成——794c14b 已 push", "AI工作戰情中心"),
      L("d5", t - 590, "captain", "Ethan 的固定英文名已上線，我核對過 origin/main 一致。Dora 設定頁做到 11 項，有 3 項要你決定預設值，做完列表給你看。"),
      L("d6", t - 120, "kang", "預設值照你建議的", "終端機"),
    ];
  },
  captainTasks: [
    { id: "T1022021500", from: "x", to: "Dora", project: "ProjectD", text: "ProjectD 設定頁：15 個選項與預設值", state: "sent" },
    { id: "T1022022000", from: "x", to: "Bella", project: "ProjectA", text: "匯出功能：先出三版版型", state: "sent" },
  ],

  /** 示範的 B1 交流互動板留言（Mac 讀 board/b1-board.jsonl；示範用假的兩則） */
  b1Posts() {
    const t = now();
    return [
      { id: 1, at: t - 7200, name: "Dora", project: "ProjectD", text: "設定頁的預設值先列成表給使用者勾，比一項一項問快很多。", re: null },
      { id: 2, at: t - 3600, name: "Ethan", project: "ProjectA", text: "同意。另外 push 前先跑閘門，省掉一輪來回。", re: 1 },
    ];
  },

  /** 示範保全（假 MAC，不是你名冊裡的）：normal｜notice｜alert */
  guardStatus(m) {
    const g = { hasData: true, knownCount: 14, onlineCount: 9, lastScan: now() - (m === "notice" ? 30 * 3600 : 25 * 60), stale: m === "notice",
                flagged: [], onlineDevices: [], pushChecked: 0, pushBlocked: 0, pushRecent: [], level: "normal", summary: "" };
    if (m === "notice") {
      g.level = "notice";
      g.flagged = [{ mac: "02:00:00:00:00:02", ip: "192.0.2.88", vendor: "示範廠商", label: "★不在你清單上的裝置", kind: "unconfirmed", online: false }];
    } else if (m !== "normal") {
      g.level = "alert";
      g.flagged = [{ mac: "02:00:00:00:00:01", ip: "192.0.2.77", vendor: "Espressif（示範）", kind: "new", online: true, firstSeen: now() - 600 },
                   { mac: "02:00:00:00:00:02", ip: "192.0.2.88", vendor: "示範廠商", label: "★不在你清單上的裝置", kind: "unconfirmed", online: true }];
    }
    const parts = [];
    if (g.stale) parts.push("很久沒掃描了");
    parts.push(`上次在線 ${g.onlineCount} 台／名冊 ${g.knownCount} 台`);
    const s = g.flagged.filter(d => d.kind !== "unconfirmed").length, p = g.flagged.length - s;
    if (s > 0) parts.push(`${s} 台沒命名`);
    if (p > 0) parts.push(`${p} 台待確認`);
    g.summary = parts.join("，") + "（示範）";
    if (g.level === "alert") {
      const t = now();
      g.pushRecent = [
        { at: t - 300, name: "Ethan", repo: "Okle42/示範", dir: "/x", refs: ["main"], commits: 2, verdict: "block", reasons: ["force push 到 main 會改寫遠端歷史"], head: "abc" },
        { at: t - 3600, name: "Dora", repo: "Okle42/示範二", dir: "/y", refs: ["main"], commits: 1, verdict: "ok", reasons: [] },
      ];
      g.pushChecked = 2; g.pushBlocked = 1;
    }
    return g;
  },
};
