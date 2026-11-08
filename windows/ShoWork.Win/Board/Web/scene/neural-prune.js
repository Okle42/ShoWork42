// ShoWorkCore/GraphPrune.swift 照搬（11-02 P8）。純函式；時間用 JS Date，大小用 Number（位元組）。
//
// 圖譜輸出的大小上限（10-22 隊長 Chris：內建碟剩 21G，Graphify 自動跑的輸出別變成下一個肥的）。
// 每個專案本來就只留一份（重跑會覆蓋），會長大的只有「專案資料夾越積越多」：
//   ① 不在大樓上超過 maxAge 的專案 ⇒ 丟垃圾桶
//   ② 加總還超過 cap ⇒ 從最久沒更新、不在大樓上的開始丟；全部都在大樓上還是超過 ⇒ 不動（寫 log，不刪正在用的）

export const GraphPrune = {
  cap: 300 * 1024 * 1024,
  maxAge: 14 * 86400,

  /** dirs：[{ name, bytes, modified: Date, active（現在大樓上有這個專案） }]。回要丟掉的資料夾名（先丟過期的，再照最舊的丟到不超過 cap） */
  pick(dirs, now, cap = GraphPrune.cap, maxAge = GraphPrune.maxAge) {
    const out = [];
    let total = dirs.reduce((s, d) => s + d.bytes, 0);
    const age = d => (now.getTime() - d.modified.getTime()) / 1000;
    for (const d of dirs) if (!d.active && age(d) > maxAge) { out.push(d.name); total -= d.bytes; }
    // Swift sorted(by: <)：穩定與否不影響（同時間的順序照原陣列，JS sort 是穩定的）
    for (const d of dirs.filter(x => !x.active && !out.includes(x.name)).sort((a, b) => a.modified - b.modified)) {
      if (!(total > cap)) continue;
      out.push(d.name); total -= d.bytes;
    }
    return out;
  },
};
