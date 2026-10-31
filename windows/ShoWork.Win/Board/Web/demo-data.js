// office.html?demo=1 的假資料（格式同 Board\Office.cs 的 OfficeSnapshot；名字、專案全是假的）
const P = (id, name, task, mood, extra = {}) => ({
  id, name, task, mood, captain: false, title: `${name}-${task}`,
  reason: { working: "工作中", waiting: "等你回答", finished: "做完了，你還沒看", stuck: "41 分鐘沒有新動靜", idle: "閒置", asleep: "閒置" }[mood],
  ...extra,
});

export const demo = {
  type: "office", version: 1,
  floors: [
    { kind: "lobby", id: "lobby", floorNo: "01", active: false, seats: 0, queued: 0, people: [], plates: [] },
    { kind: "idle", id: "idle-0", floorNo: "", active: false, seats: 0, queued: 0, people: [],
      plates: [{ name: "ProjectF", floorNo: "07" }, { name: "ProjectG", floorNo: "08" }] },
    { kind: "project", id: "p:projecta", floorNo: "02", project: "ProjectA", number: 2, active: true, seats: 4, queued: 1,
      theme: "monitor", themeTitle: "監控中心", accent: "#5B8DB8",
      people: [
        P("a1", "Alice", "派工與名冊整理", "working", { accessory: "crown", captain: true }),
        P("a2", "Bob", "要不要上線？", "waiting"),
        P("a3", "Carol", "設定頁深色模式", "finished"),
        P("a4", "Dave", "安裝包簽章", "stuck"),
      ] },
    { kind: "project", id: "p:projectb", floorNo: "03", project: "ProjectB", number: 3, active: true, seats: 2, queued: 0,
      theme: "library", themeTitle: "研究書房", accent: "#9C6B4E",
      people: [
        P("b1", "Eve", "法規研究", "working", { accessory: "glasses" }),
        P("b2", "Grace", "README 英文版", "idle"),
      ] },
    { kind: "project", id: "p:projectc", floorNo: "04", project: "ProjectC", number: 4, active: true, seats: 3, queued: 0,
      theme: "call_room", themeTitle: "秘書電話室", accent: "#8C7BB5",
      people: [
        P("c1", "Heidi", "自動回覆草稿", "waiting", { accessory: "headset" }),
        P("c2", "Ivan", "平板連線檢查", "working", { accessory: "headset" }),
        P("c3", "Judy", "未命名", "asleep"),
      ] },
    { kind: "project", id: "p:projectd", floorNo: "05", project: "ProjectD", number: 5, active: true, seats: 1, queued: 0,
      theme: "print_shop", themeTitle: "3D 列印工坊", accent: "#C98B3C",
      people: [P("d1", "Kim", "外殼切片", "working")] },
    { kind: "project", id: "p:projecte", floorNo: "06", project: "ProjectE", number: 6, active: false, seats: 0, queued: 0,
      theme: "game_lab", themeTitle: "遊戲工作室", accent: "#7A5FA8", people: [] },
    { kind: "roof", id: "roof", floorNo: "RF", active: false, seats: 0, queued: 0, people: [], plates: [] },
  ],
  counts: { working: 4, waiting: 2, finished: 1, stuck: 1 },
  colors: {},
  reduceMotion: false,
};
