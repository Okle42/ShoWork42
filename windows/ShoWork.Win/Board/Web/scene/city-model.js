// ShoWorkCore/City.swift 的 3D 需要的那部分照搬（11-02）：CityState 的計算屬性（id、used、alert、gates⋯）、CityRules、CityText、CityBox。
// 資料來源是 bench/mac-input.json 的 city（Mac 用 Mirror dump 出來）：只有存起來的欄位，計算屬性在這裡補成 getter。
// 欄位形狀照 JSON：時間是 Unix 秒（Swift 的 Date）、grid.stage 是字串（"normal"／"dim"／"flicker"／"blackout"）。
// 解析（CityParse）、收集（CitySource）不在這裡：Windows 有自己的資料來源。

const sec = d => d === null || d === undefined ? null : d instanceof Date ? d.getTime() / 1000 : Number(d);
const nowSec = () => Date.now() / 1000;
/** Swift 的 Double.rounded()（四捨五入、.5 遠離 0） */
export const swiftRound = x => Math.sign(x) * Math.round(Math.abs(x));

// MARK: - 資料

/** 一個磁碟（內建碟的資料卷、/Volumes 底下的外接碟；拔掉的外接碟只剩名字） */
export class CityDisk {
  constructor(o = {}) {
    this.name = o.name ?? ""; this.isInternal = !!o.isInternal; this.mounted = o.mounted ?? true;
    this.total = o.total ?? 0; this.available = o.available ?? 0;
    this.availablePlain = o.availablePlain ?? 0; this.format = o.format ?? null; this.mountPath = o.mountPath ?? null;
    this.lastSeen = sec(o.lastSeen);
  }
  get id() { return `city:disk:${this.name}`; }
  /** 已用比例（0…1）；拿不到容量＝null */
  get used() {
    if (!(this.mounted && this.total > 0)) return null;
    return Math.min(1, Math.max(0, (this.total - this.available) / this.total));
  }
  get alert() { return (this.used ?? 0) >= CityRules.fullAt; }
}

/** iCloud 同步狀態 */
export class CloudSync {
  constructor(o = {}) {
    this.remaining = o.remaining ?? null; this.driveState = o.driveState ?? null; this.lastSync = sec(o.lastSync);
    this.caughtUp = !!o.caughtUp; this.pending = o.pending ?? 0; this.blocked = o.blocked ?? 0; this.desktopDocs = o.desktopDocs ?? null;
  }
  /** 剩下多少算「額度快滿」：5 GB */
  static lowQuota = 5_000_000_000;
  /** 主容器不是 idle 而且超過 1 小時沒同步成功＝卡住 */
  stuck(now) {
    const st = this.driveState;
    if (st === null || st === "idle") return false;
    if (this.lastSync === null) return true;
    return sec(now) - this.lastSync > 3600;
  }
  alert(now) { return this.stuck(now) || this.blocked > 0 || (this.remaining !== null ? this.remaining < CloudSync.lowQuota : false); }
}

/** 雲端（飛艇） */
export class CityCloud {
  constructor(o = {}) {
    this.name = o.name ?? ""; this.isICloud = !!o.isICloud; this.sync = o.sync ? new CloudSync(o.sync) : null; this.checkedAt = sec(o.checkedAt);
  }
  get id() { return `city:cloud:${this.name}`; }
  get alert() { return this.sync ? this.sync.alert(this.checkedAt ?? nowSec()) : false; }
  /** 狀態燈：拿得到同步資訊＝綠（警示＝紅）；只知道連著＝灰 */
  get known() { return this.sync !== null; }
}

/** ssh 伺服器（分公司） */
export class CityServer {
  constructor(o = {}) {
    this.alias = o.alias ?? ""; this.online = o.online ?? null; this.checkedAt = sec(o.checkedAt); this.lastOnline = sec(o.lastOnline);
    this.latencyMs = o.latencyMs ?? null; this.hostName = o.hostName ?? null; this.port = o.port ?? null;
  }
  get id() { return `city:server:${this.alias}`; }
  get alert() { return this.online === false; }
}

/** 一個在聽 TCP 的埠 */
export class ListenPort {
  constructor(o = {}) { this.port = o.port ?? 0; this.process = o.process ?? ""; this.external = !!o.external; this.knownOpen = o.knownOpen ?? null; }
  get openRed() { return this.external && this.knownOpen !== null; }
}

/** 防火牆（城牆＋城門） */
export class CityFirewall {
  constructor(o = {}) { this.enabled = o.enabled ?? null; this.ports = (o.ports ?? []).map(p => new ListenPort(p)); this.checkedAt = sec(o.checkedAt); }
  get gates() { return this.ports.filter(p => p.external); }
  get doors() { return this.ports.filter(p => !p.external); }
  get openRed() { return this.ports.filter(p => p.openRed); }
}

/** 電廠＝AI 額度。stage 用字串（JSON 的形狀）；比大小用 CityGrid.rank */
export class CityGrid {
  static stages = ["normal", "dim", "flicker", "blackout"];
  static rank(s) { const i = CityGrid.stages.indexOf(s); return i < 0 ? 0 : i; }
  constructor(o = {}) {
    this.fiveUsed = o.fiveUsed ?? null; this.fiveReset = sec(o.fiveReset); this.sevenUsed = o.sevenUsed ?? null; this.sevenReset = sec(o.sevenReset);
    this.stage = typeof o.stage === "number" ? CityGrid.stages[o.stage] : (o.stage ?? "normal");
    this.sevenLeftMin = o.sevenLeftMin ?? null;
  }
  get known() { return this.fiveUsed !== null; }
  get fiveLeft() { return this.fiveUsed === null ? null : Math.max(0, Math.min(100, 100 - this.fiveUsed)); }
  get sevenLeft() { return this.sevenUsed === null ? null : Math.max(0, Math.min(100, 100 - this.sevenUsed)); }
  get alert() { return CityGrid.rank(this.stage) >= 2; }
  get lightScale() { return [1, 0.6, 0.35, 0][CityGrid.rank(this.stage)]; }
}

/** cool42（頂樓冷卻水塔） */
export class CityPower {
  constructor(o = {}) { this.temp = o.temp ?? null; this.cpuAvg = o.cpuAvg ?? null; this.level = o.level ?? null; this.stale = !!o.stale; }
  get known() { return this.temp !== null && !this.stale; }
  get alert() { return this.known && (this.level === "hot" || this.level === "critical"); }
}

/** GitHub 港口的船 */
export class CityShip {
  constructor(o = {}) { this.repo = o.repo ?? ""; this.at = sec(o.at) ?? 0; this.inbound = !!o.inbound; }
  get id() { return `${this.repo}@${Math.trunc(this.at)}${this.inbound ? "<" : ""}`; }
}

export class CityState {
  constructor(o = {}) {
    this.disks = (o.disks ?? []).map(d => new CityDisk(d));
    this.clouds = (o.clouds ?? []).map(c => new CityCloud(c));
    this.servers = (o.servers ?? []).map(s => new CityServer(s));
    this.firewall = new CityFirewall(o.firewall ?? {});
    this.power = new CityPower(o.power ?? {});
    this.grid = new CityGrid(o.grid ?? {});
    this.ships = (o.ships ?? []).map(s => new CityShip(s));
    this.repos = o.repos ?? 0;
    this.recent = (o.recent ?? []).map(s => new CityShip(s));
    this.demo = !!o.demo;
  }
  /** JSON（mac-input.json 的 city）或已經是 CityState 都收 */
  static from(o) { return o instanceof CityState ? o : new CityState(o ?? {}); }
  /** Swift 的 ==：存起來的欄位全部一樣（getter 不進 JSON） */
  static same(a, b) { return JSON.stringify(a) === JSON.stringify(b); }
}

// MARK: - 規則

export const CityRules = {
  /** 用到幾 % 算滿 */
  fullAt: 0.9,
  /** 一個堆場：一層 12 格、最多 4 層 */
  perLevel: 12, maxLevels: 4,
  /** 已用比例 → {count, levels, overflow}。層數＝已用比例×4 無條件進位；有用到就至少 1 個 */
  containers(used) {
    const u = used;
    if (u === null || u === undefined || !(u > 0)) return { count: 0, levels: 0, overflow: 0 };
    const levels = Math.min(this.maxLevels, Math.max(1, Math.trunc(Math.ceil(u * this.maxLevels - 1e-9))));
    const c = Math.min(this.perLevel * this.maxLevels, Math.max((levels - 1) * this.perLevel + 1, Math.trunc(swiftRound(u * this.perLevel * this.maxLevels))));
    const over = u >= this.fullAt ? Math.min(6, 2 + Math.trunc(Math.floor((u - this.fullAt) * 40 + 1e-9))) : 0;
    return { count: c, levels, overflow: over };
  },
  tempStep(t) { return Math.trunc(swiftRound(t / 10)) * 10; },
  /** 名牌上的「已用 %」：四捨五入到整數 */
  pct(used) { return used === null || used === undefined ? null : Math.trunc(swiftRound(used)); },
};

// MARK: - 文字

const p2 = n => String(n).padStart(2, "0");
const fmt1 = x => (Math.round(x * 10) / 10).toFixed(1);

export const CityText = {
  bytes(b) {
    const g = b / 1e9;
    if (g >= 1000) return `${fmt1(g / 1000)}T`;
    if (g >= 10) return `${Math.trunc(swiftRound(g))}G`;
    return `${fmt1(g)}G`;
  },
  diskName(d) { return d.isInternal ? "內建碟" : d.name; },
  /** 名牌：內建碟寫剩多少、外接碟寫已用 %、拔掉的寫已拔除；≥90% 加 ⚠ */
  disk(d) {
    if (!d.mounted) return `${this.diskName(d)}・已拔除`;
    const u = d.used;
    if (u === null) return `${this.diskName(d)}・容量讀不到`;
    const pct = u > 0 && u < 0.005 ? "<1%" : `${Math.trunc(swiftRound(u * 100))}%`;
    const body = d.isInternal ? `${this.diskName(d)}・剩 ${this.bytes(d.available)}` : `${this.diskName(d)}・${pct}`;
    return d.alert ? body + (d.isInternal ? `（${Math.trunc(swiftRound(u * 100))}%）` : "") + " ⚠" : body;
  },
  cloud(c) {
    const s = c.sync;
    if (!(c.isICloud && s)) return `${c.isICloud ? "iCloud" : c.name}・已連線`;
    const now = c.checkedAt ?? nowSec();
    if (s.stuck(now)) return "iCloud・同步卡住 ⚠";
    if (s.blocked > 0) return `iCloud・${s.blocked} 項被擋 ⚠`;
    const r = s.remaining;
    if (r === null) return "iCloud・已連線";
    return `iCloud・剩 ${this.bytes(r)}` + (r < CloudSync.lowQuota ? " ⚠" : "");
  },
  server(s) { return `${s.alias}・` + (s.online === null ? "檢查中" : s.online ? "在線" : "離線 ⚠"); },
  wall(f) {
    if (f.checkedAt === null) return "城牆・還沒檢查";
    if (f.enabled === null) return "城牆・防火牆狀態未知";
    return f.enabled ? "城牆・防火牆開啟" : "城牆・防火牆關閉 ⚠";
  },
  gate(p) { return `${p.port} ${p.knownOpen ?? p.process}・敞開 ⚠`; },
  /** 時間：今天＝HH:mm、不是今天＝M/d HH:mm（本機時區） */
  clock(d, now) {
    const a = new Date(sec(d) * 1000), b = new Date(sec(now) * 1000);
    const same = a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
    const hm = `${p2(a.getHours())}:${p2(a.getMinutes())}`;
    return same ? hm : `${a.getMonth() + 1}/${a.getDate()} ${hm}`;
  },
  /** 電廠名牌：5 小時已用多少＋幾點重置；停電＝幾點復電 */
  grid(g, now) {
    const used = CityRules.pct(g.fiveUsed);
    if (used === null) return "電廠・額度讀不到";
    const at = g.fiveReset !== null ? this.clock(g.fiveReset, now) : null;
    if (g.stage === "blackout") {
      const fiveOut = (g.fiveUsed ?? 0) >= 100;
      const back = fiveOut ? at : g.sevenReset !== null ? this.clock(g.sevenReset, now) : null;
      return "停電・額度用完" + (back !== null ? `，${back} 復電` : "") + " ⚠";
    }
    const s = `電廠・5 小時已用 ${used}%` + (at !== null ? `（${at} 重置）` : "");
    return g.alert ? s + " ⚠" : s;
  },
  countdown(min) {
    if (min === null || min === undefined) return null;
    const m = min;
    if (m >= 1440) return `${Math.trunc(m / 1440)} 天 ${Math.trunc(m % 1440 / 60)} 小時`;
    if (m >= 60) return `${Math.trunc(m / 60)} 小時 ${Math.trunc(m % 60 / 10) * 10} 分`;
    return `${Math.max(m, 0)} 分`;
  },
  /** 油槽名牌：7 天已用多少＋還有多久重置 */
  fuel(g) {
    const l = g.sevenLeft, used = CityRules.pct(g.sevenUsed);
    if (l === null || used === null) return "油槽・7 天額度讀不到";
    const c = this.countdown(g.sevenLeftMin);
    return `油槽・7 天已用 ${used}%` + (c !== null ? `（${c}後重置）` : "") + (l <= 5 ? " ⚠" : "");
  },
};

// MARK: - 穿插檢查

/** IEEE remainder（Swift 的 remainder(_:_:)：商取最近的整數、平手取偶數） */
function remainder(x, y) {
  const q = x / y, n = Math.round(q);
  const k = Math.abs(q - Math.trunc(q)) === 0.5 ? 2 * Math.round(q / 2) : n;
  return x - k * y;
}

/** 一個方塊：中心、長寬高、繞 Y 軸轉的角度（VoxelMesh.log 記的 {center, size, yaw}） */
export const CityBox = {
  rotated(b) { return Math.abs(remainder(b.yaw ?? 0, Math.PI / 2)) > 1e-4; },
  axes(b) { const c = Math.cos(b.yaw ?? 0), s = Math.sin(b.yaw ?? 0); return [[c, -s], [s, c]]; },
  /** 兩個方塊互相插進去多深（公尺；≤0＝沒碰到或只是貼著）。分離軸：上下＋水平面 4 條軸，取最小的重疊量 */
  penetration(a, b) {
    const dy = Math.min(a.center[1] + a.size[1] / 2, b.center[1] + b.size[1] / 2) - Math.max(a.center[1] - a.size[1] / 2, b.center[1] - b.size[1] / 2);
    if (!(dy > 0)) return dy;
    const [ax, az] = this.axes(a), [bx, bz] = this.axes(b);
    const d = [b.center[0] - a.center[0], b.center[2] - a.center[2]];
    const dot = (u, v) => u[0] * v[0] + u[1] * v[1];
    let best = dy;
    for (const n of [ax, az, bx, bz]) {
      const r = (box, u, w) => Math.abs(dot(u, n)) * box.size[0] / 2 + Math.abs(dot(w, n)) * box.size[2] / 2;
      const overlap = r(a, ax, az) + r(b, bx, bz) - Math.abs(dot(d, n));
      if (overlap <= 0) return overlap;
      best = Math.min(best, overlap);
    }
    return best;
  },
};
