import Foundation
import simd

// 外部空間城市（10-21 Kang 拍板）：把這台 Mac 的外部資源畫成科技大樓四周的城市。
//   硬碟＝貨櫃堆場、雲端＝飛艇、ssh 伺服器＝對街分公司、防火牆＝城牆＋城門、cool42＝電廠、GitHub＝港口。
// 這裡只有純邏輯（可測）：資料結構、各種輸出的解析、容量→貨櫃、警示判定。
// 收集在 ShoWorkAgent/CitySource.swift（背景 queue），畫面在 ShoWorkAgent/OfficeCity.swift。
// 原則：只寫確定的事實（讀不到總額度就不寫總額度），不瞎掰數字、不寫「狀態未知」；帳號（雲端資料夾名裡的信箱）不顯示。

// MARK: - 資料

/// 一個磁碟（內建碟的資料卷、/Volumes 底下的外接碟；拔掉的外接碟只剩名字）
public struct CityDisk: Sendable, Equatable, Codable {
    public var name: String
    public var isInternal: Bool
    public var mounted: Bool
    public var total: Int64          // bytes；拔掉的＝0
    public var available: Int64      // 你能用的（內建碟＝「重要用途可用」，含系統可清出的空間）
    // 10-21 懸停卡用的細節（不影響 3D 造型）
    public var availablePlain: Int64 = 0     // 檔案系統回報的「現在空著的」（不含可清出的）
    public var format: String?               // 檔案系統（APFS、MS-DOS (FAT32)⋯）
    public var mountPath: String?
    public var lastSeen: Date?               // 拔掉的外接碟：最後一次看到插著的時間（這版之前拔掉的不知道）
    public init(name: String, isInternal: Bool, mounted: Bool = true, total: Int64 = 0, available: Int64 = 0,
                availablePlain: Int64 = 0, format: String? = nil, mountPath: String? = nil, lastSeen: Date? = nil) {
        self.name = name; self.isInternal = isInternal; self.mounted = mounted; self.total = total; self.available = available
        self.availablePlain = availablePlain; self.format = format; self.mountPath = mountPath; self.lastSeen = lastSeen
    }
    public var id: String { "city:disk:\(name)" }
    /// 已用比例（0…1）；拿不到容量＝nil
    public var used: Double? {
        guard mounted, total > 0 else { return nil }
        return min(1, max(0, Double(total - available) / Double(total)))
    }
    public var alert: Bool { (used ?? 0) >= CityRules.fullAt }
}

/// iCloud 同步狀態（10-21：`brctl quota`／`brctl status` 讀得到的事實；總額度讀不到就不寫）
public struct CloudSync: Sendable, Equatable {
    public var remaining: Int64?         // 帳號剩餘額度（bytes）
    public var driveState: String?       // iCloud Drive 主容器（com.apple.CloudDocs）的 client 狀態：idle／needs-sync／blocked-⋯
    public var lastSync: Date?           // 主容器上次同步
    public var caughtUp = false          // 主容器 caught-up（跟伺服器一致）
    public var pending = 0               // 其他還在用的 App 容器裡「待同步」的個數（App 已刪除、停用同步的不算）
    public var blocked = 0               // 其他還在用的容器裡被擋住（blocked-*，不含 App 已刪除）的個數
    public var desktopDocs: Bool?        // 「桌面與文件」同步開著嗎
    public init(remaining: Int64? = nil, driveState: String? = nil, lastSync: Date? = nil, caughtUp: Bool = false,
                pending: Int = 0, blocked: Int = 0, desktopDocs: Bool? = nil) {
        self.remaining = remaining; self.driveState = driveState; self.lastSync = lastSync; self.caughtUp = caughtUp
        self.pending = pending; self.blocked = blocked; self.desktopDocs = desktopDocs
    }
    /// 剩下多少算「額度快滿」：總額度讀不到 ⇒ 用絕對值 5 GB（50 GB 方案的 10%、200 GB 方案的 2.5%）
    public static let lowQuota: Int64 = 5_000_000_000
    /// 主容器不是 idle 而且超過 1 小時沒同步成功＝卡住（剛存檔時短暫 needs-sync 是正常的）
    public func stuck(now: Date) -> Bool {
        guard let st = driveState, st != "idle" else { return false }
        guard let t = lastSync else { return true }
        return now.timeIntervalSince(t) > 3600
    }
    public func alert(now: Date) -> Bool { stuck(now: now) || blocked > 0 || (remaining.map { $0 < Self.lowQuota } ?? false) }
}

/// 雲端（飛艇）：只放誠實拿得到的狀態
public struct CityCloud: Sendable, Equatable {
    public var name: String
    public var isICloud: Bool
    public var sync: CloudSync?          // iCloud：brctl 讀到的；nil＝讀不到（只知道資料夾在）
    public var checkedAt: Date?
    public init(name: String, isICloud: Bool = false, sync: CloudSync? = nil, checkedAt: Date? = nil) {
        self.name = name; self.isICloud = isICloud; self.sync = sync; self.checkedAt = checkedAt
    }
    public var id: String { "city:cloud:\(name)" }
    public var alert: Bool { sync?.alert(now: checkedAt ?? Date()) ?? false }
    /// 狀態燈：拿得到同步資訊＝綠（警示＝紅）；只知道連著＝灰
    public var known: Bool { sync != nil }
}

/// ssh 伺服器（對街分公司）
public struct CityServer: Sendable, Equatable {
    public var alias: String
    public var online: Bool?         // nil＝還沒連過
    public var checkedAt: Date?
    public var lastOnline: Date?     // 上次連上的時間
    public var latencyMs: Int?       // 上次連上花多久（TCP 握手）
    public var hostName: String?
    public var port: Int?
    public init(alias: String, online: Bool? = nil, checkedAt: Date? = nil, lastOnline: Date? = nil, latencyMs: Int? = nil,
                hostName: String? = nil, port: Int? = nil) {
        self.alias = alias; self.online = online; self.checkedAt = checkedAt; self.lastOnline = lastOnline; self.latencyMs = latencyMs
        self.hostName = hostName; self.port = port
    }
    public var id: String { "city:server:\(alias)" }
    public var alert: Bool { online == false }
}

/// 一個在聽 TCP 的埠
public struct ListenPort: Sendable, Equatable {
    public var port: Int
    public var process: String
    public var external: Bool        // 綁 *、0.0.0.0、:: 或區網位址（別台電腦連得到）
    public var knownOpen: String?    // 已知沒有認證的（敞開的紅門）：名稱
    public init(port: Int, process: String, external: Bool, knownOpen: String? = nil) {
        self.port = port; self.process = process; self.external = external; self.knownOpen = knownOpen
    }
    public var openRed: Bool { external && knownOpen != nil }
}

/// 防火牆（城牆＋城門）
public struct CityFirewall: Sendable, Equatable {
    public var enabled: Bool?        // nil＝讀不到
    public var ports: [ListenPort] = []
    public var checkedAt: Date?
    public init(enabled: Bool? = nil, ports: [ListenPort] = [], checkedAt: Date? = nil) { self.enabled = enabled; self.ports = ports; self.checkedAt = checkedAt }
    public var gates: [ListenPort] { ports.filter(\.external) }
    public var doors: [ListenPort] { ports.filter { !$0.external } }
    public var openRed: [ListenPort] { ports.filter(\.openRed) }
    /// 保全卡片的一句城牆摘要
    public var summary: String {
        guard checkedAt != nil else { return "城牆：還沒檢查" }
        var s = enabled == nil ? "城牆：防火牆狀態讀不到" : enabled! ? "城牆：防火牆開著" : "城牆：防火牆關閉（有缺口）"
        s += "，對外城門 \(gates.count) 個、城內的門 \(doors.count) 扇"
        if !openRed.isEmpty { s += "，敞開的紅門 " + openRed.map { "\($0.port)（\($0.knownOpen!)）" }.joined(separator: "、") }
        return s
    }
}

/// 電廠＝AI 額度（10-22 Kang 拍板：5 小時額度＝電力，用完公司停電；7 天額度＝油槽）。資料來自 statusLine 存的 rate_limits.json
public struct CityGrid: Sendable, Equatable {
    public enum Stage: Int, Sendable, Comparable {
        case normal, dim, flicker, blackout       // <80%、80–95%、95–100%、100%（重置前）
        public static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
    }
    public var fiveUsed: Double?         // 0–100；nil＝讀不到
    public var fiveReset: Date?
    public var sevenUsed: Double?
    public var sevenReset: Date?
    public var stage: Stage = .normal
    /// 7 天重置倒數（分鐘；算的那一刻）：油槽名牌寫「還有多久重置」用
    public var sevenLeftMin: Int?
    public init(fiveUsed: Double? = nil, fiveReset: Date? = nil, sevenUsed: Double? = nil, sevenReset: Date? = nil, stage: Stage = .normal) {
        self.fiveUsed = fiveUsed; self.fiveReset = fiveReset; self.sevenUsed = sevenUsed; self.sevenReset = sevenReset; self.stage = stage
    }
    public var known: Bool { fiveUsed != nil }
    /// 剩多少（0–100）
    public var fiveLeft: Double? { fiveUsed.map { max(0, min(100, 100 - $0)) } }
    public var sevenLeft: Double? { sevenUsed.map { max(0, min(100, 100 - $0)) } }
    public var alert: Bool { stage >= .flicker }
    /// 燈光乘數（燈、補光、發光材質）
    public var lightScale: Double {
        switch stage { case .normal: 1; case .dim: 0.6; case .flicker: 0.35; case .blackout: 0 }
    }
}

/// cool42（頂樓冷卻水塔；10-22 起電廠改代表額度）
public struct CityPower: Sendable, Equatable {
    public var temp: Double?
    public var cpuAvg: Double?
    public var level: String?        // ok／warm／hot／critical
    public var stale = false         // 狀態檔超過 2 分鐘沒更新
    public init(temp: Double? = nil, cpuAvg: Double? = nil, level: String? = nil, stale: Bool = false) {
        self.temp = temp; self.cpuAvg = cpuAvg; self.level = level; self.stale = stale
    }
    public var known: Bool { temp != nil && !stale }
    public var alert: Bool { known && (level == "hot" || level == "critical") }
}

/// GitHub 港口：剛 push／fetch 的 repo（一艘出港的貨船）
public struct CityShip: Sendable, Equatable {
    public var repo: String
    public var at: Date
    public init(repo: String, at: Date) { self.repo = repo; self.at = at }
    public var id: String { "\(repo)@\(Int(at.timeIntervalSince1970))" }
}

public struct CityState: Sendable, Equatable {
    public var disks: [CityDisk] = []
    public var clouds: [CityCloud] = []
    public var servers: [CityServer] = []
    public var firewall = CityFirewall()
    public var power = CityPower()
    public var grid = CityGrid()
    public var ships: [CityShip] = []
    public var repos = 0             // 港口看著幾個 repo
    public var recent: [CityShip] = []   // 最近有新遠端 ref 的 repo（新到舊，最多 5 個；時間＝ref 檔的 mtime）
    public var demo = false
    public init() {}

    /// 設備警示（頂部「需要你」列的一類）：≥90% 的碟、離線的伺服器、防火牆關、敞開的紅門、cool42 hot 以上
    public var alerts: [CityAlert] {
        var a: [CityAlert] = []
        for d in disks where d.alert { a.append(CityAlert(id: d.id, text: "\(CityText.diskName(d)) 已用 \(Int(((d.used ?? 0) * 100).rounded()))%")) }
        for s in servers where s.alert { a.append(CityAlert(id: s.id, text: "\(s.alias) 離線")) }
        if firewall.enabled == false { a.append(CityAlert(id: "city:wall", text: "防火牆關閉")) }
        for p in firewall.openRed { a.append(CityAlert(id: "city:gate:\(p.port)", text: "\(p.port) \(p.knownOpen!) 對外敞開")) }
        if power.alert { a.append(CityAlert(id: "city:cooler", text: "cool42 \(power.level ?? "")")) }
        if grid.alert { a.append(CityAlert(id: "city:power", text: CityText.gridAlert(grid))) }
        for c in clouds where c.alert { a.append(CityAlert(id: c.id, text: CityText.cloud(c))) }
        return a
    }
}

public struct CityAlert: Sendable, Equatable, Identifiable {
    public var id: String
    public var text: String
    public init(id: String, text: String) { self.id = id; self.text = text }
}

// MARK: - 規則

public enum CityRules {
    /// 用到幾 % 算滿（貨櫃堆到圍籬外、紅色警示燈）
    public static let fullAt = 0.9
    /// 一個堆場：一層 12 格、最多 4 層
    public static let perLevel = 12, maxLevels = 4

    /// 已用比例 → (貨櫃數, 層數, 圍籬外的貨櫃數)。層數＝已用比例×4 無條件進位；有用到就至少 1 個
    public static func containers(used: Double?) -> (count: Int, levels: Int, overflow: Int) {
        guard let u = used, u > 0 else { return (0, 0, 0) }
        let levels = min(maxLevels, max(1, Int(ceil(u * Double(maxLevels) - 1e-9))))
        // 貨櫃數照比例，但至少要堆到第 levels 層（最上層至少 1 個）
        let c = min(perLevel * maxLevels, max((levels - 1) * perLevel + 1, Int((u * Double(perLevel * maxLevels)).rounded())))
        let over = u >= fullAt ? min(6, 2 + Int(((u - fullAt) * 40 + 1e-9).rounded(.down))) : 0
        return (c, levels, over)
    }

    /// 冷卻塔的煙：0…5 團（50°C 以下沒煙、每 8°C 多一團）；拿不到溫度＝0
    public static func smoke(_ p: CityPower) -> Int {
        guard p.known, let t = p.temp else { return 0 }
        return min(5, max(0, (tempStep(t) - 40) / 10))      // 50°C 一團、每 10°C 多一團（跟名牌同一格，不會一個變一個沒變）
    }

    /// 溫度變化要不要重畫：等級變了、或顯示的溫度（10°C 一格）換格才算（cool42 每 5 秒改寫、溫度跟著負載一直跳，不要每次都重畫）
    public static func powerChanged(_ a: CityPower, _ b: CityPower) -> Bool {
        // 煙量不單獨比：它由溫度算，剛好卡在分界（例如 74°C）會來回跳；溫度差 2°C 以上才換，煙量跟著換
        if a.level != b.level || a.stale != b.stale || (a.temp == nil) != (b.temp == nil) { return true }
        // 名牌只寫到 10°C（約 70°C）：換了一格、而且跟上次差 6°C 以上才算（10-21 實測：機器忙時控制溫度 15 秒內會在 70–78 間跳，
        // 5°C 一格時每分鐘重畫 4 次，閒置 CPU 多約 0.3 秒／分鐘）
        if let x = a.temp, let y = b.temp, tempStep(x) != tempStep(y), abs(x - y) >= 6 { return true }
        return false
    }

    /// 溫度顯示到 10°C 一格
    public static func tempStep(_ t: Double) -> Int { Int((t / 10).rounded()) * 10 }

    /// 額度 → 電網（重置時間已過＝新的一輪，當成 0%）
    public static func grid(_ r: RateLimits?, now: Date) -> CityGrid {
        guard let r = r?.current(now: now) else { return CityGrid() }
        var g = CityGrid(fiveUsed: r.fiveHour?.used, fiveReset: r.fiveHour?.resetsAt, sevenUsed: r.sevenDay?.used, sevenReset: r.sevenDay?.resetsAt)
        let u = max(r.fiveHour?.used ?? 0, r.sevenDay?.used ?? 0)      // 7 天用完也一樣停電
        g.stage = u >= 100 ? .blackout : u >= 95 ? .flicker : u >= 80 ? .dim : .normal
        g.sevenLeftMin = g.sevenReset.map { max(0, Int($0.timeIntervalSince(now) / 60)) }
        return g
    }
    /// 剩餘量的格（5% 一格；電表、名牌用這個，不跟著每 1% 重畫）
    public static func gridStep(_ left: Double?) -> Int? { left.map { Int(($0 / 5).rounded(.down)) * 5 } }
    /// 要不要換：階段變了、剩餘量換格、重置時間（分鐘）變了才算
    public static func gridChanged(_ a: CityGrid, _ b: CityGrid) -> Bool {
        func m(_ d: Date?) -> Int? { d.map { Int($0.timeIntervalSince1970 / 60) } }
        return a.stage != b.stage || gridStep(a.fiveLeft) != gridStep(b.fiveLeft) || gridStep(a.sevenLeft) != gridStep(b.sevenLeft)
            || m(a.fiveReset) != m(b.fiveReset) || m(a.sevenReset) != m(b.sevenReset)
            || CityText.countdown(a.sevenLeftMin) != CityText.countdown(b.sevenLeftMin)     // 倒數字變了（超過 1 天每小時、1 天內每 10 分鐘）
    }

    /// 已知沒有認證的埠（敞開的紅門）
    public static let knownOpen: [Int: String] = [9888: "audio-bridge"]
}

// MARK: - 文字

public enum CityText {
    public static func bytes(_ b: Int64) -> String {
        let g = Double(b) / 1e9
        if g >= 1000 { return String(format: "%.1fT", g / 1000) }
        if g >= 10 { return "\(Int(g.rounded()))G" }
        return String(format: "%.1fG", g)
    }
    public static func diskName(_ d: CityDisk) -> String { d.isInternal ? "內建碟" : d.name }

    /// 名牌：內建碟寫剩多少、外接碟寫已用 %、拔掉的寫已拔除；≥90% 加 ⚠
    public static func disk(_ d: CityDisk) -> String {
        guard d.mounted else { return "\(diskName(d))・已拔除" }
        guard let u = d.used else { return "\(diskName(d))・容量讀不到" }
        // 10-21：有用到但不到 0.5%（空隨身碟）原本寫「0%」卻有一個貨櫃 ⇒ 寫「<1%」
        let pct = u > 0 && u < 0.005 ? "<1%" : "\(Int((u * 100).rounded()))%"
        let body = d.isInternal ? "\(diskName(d))・剩 \(bytes(d.available))" : "\(diskName(d))・\(pct)"
        return d.alert ? body + (d.isInternal ? "（\(Int((u * 100).rounded()))%）" : "") + " ⚠" : body
    }
    /// 雲端名牌：iCloud 讀得到＝剩多少（卡住／快滿加 ⚠）；其他雲端只寫確定的事實「已連線」（資料夾掛著）
    public static func cloud(_ c: CityCloud) -> String {
        guard c.isICloud, let s = c.sync else { return "\(c.isICloud ? "iCloud" : c.name)・已連線" }
        let now = c.checkedAt ?? Date()
        if s.stuck(now: now) { return "iCloud・同步卡住 ⚠" }
        if s.blocked > 0 { return "iCloud・\(s.blocked) 項被擋 ⚠" }
        guard let r = s.remaining else { return "iCloud・已連線" }
        return "iCloud・剩 \(bytes(r))" + (r < CloudSync.lowQuota ? " ⚠" : "")
    }
    public static func server(_ s: CityServer) -> String {
        "\(s.alias)・" + (s.online == nil ? "檢查中" : s.online! ? "在線" : "離線 ⚠")
    }
    public static func wall(_ f: CityFirewall) -> String {
        guard f.checkedAt != nil else { return "城牆・還沒檢查" }
        guard let e = f.enabled else { return "城牆・防火牆狀態未知" }
        return e ? "城牆・防火牆開啟" : "城牆・防火牆關閉 ⚠"
    }
    public static func gate(_ p: ListenPort) -> String { "\(p.port) \(p.knownOpen ?? p.process)・敞開 ⚠" }
    public static func power(_ p: CityPower) -> String {
        guard let t = p.temp else { return "冷卻水塔・cool42 狀態未知" }
        if p.stale { return "冷卻水塔・cool42 沒在更新" }
        let s = "冷卻水塔・約 \(CityRules.tempStep(t))°C"
        return p.alert ? s + " \(p.level ?? "") ⚠" : s
    }
    /// 時間：今天＝HH:mm、不是今天＝M/d HH:mm
    public static func clock(_ d: Date, now: Date, tz: TimeZone = .current) -> String {
        var c = Calendar(identifier: .gregorian); c.timeZone = tz
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz
        f.dateFormat = c.isDate(d, inSameDayAs: now) ? "HH:mm" : "M/d HH:mm"
        return f.string(from: d)
    }
    /// 電廠名牌：5 小時剩多少＋幾點重置；停電＝幾點復電
    public static func grid(_ g: CityGrid, now: Date, tz: TimeZone = .current) -> String {
        guard let left = g.fiveLeft else { return "電廠・額度讀不到" }
        let at = g.fiveReset.map { clock($0, now: now, tz: tz) }
        if g.stage == .blackout {
            let fiveOut = (g.fiveUsed ?? 0) >= 100
            let back = fiveOut ? at : g.sevenReset.map { clock($0, now: now, tz: tz) }
            return "停電・額度用完" + (back.map { "，\($0) 復電" } ?? "") + " ⚠"
        }
        let s = "電廠・5 小時剩 \(CityRules.gridStep(left) ?? 0)%" + (at.map { "（\($0) 重置）" } ?? "")
        return g.alert ? s + " ⚠" : s
    }
    /// 倒數字：超過 1 天「N 天 H 小時」、1 天內「H 小時 M 分」（10 分鐘一格）、1 小時內「M 分」
    public static func countdown(_ min: Int?) -> String? {
        guard let m = min else { return nil }
        if m >= 1440 { return "\(m / 1440) 天 \(m % 1440 / 60) 小時" }
        if m >= 60 { return "\(m / 60) 小時 \(m % 60 / 10 * 10) 分" }
        return "\(max(m, 0)) 分"
    }
    /// 油槽名牌：7 天剩多少＋還有多久重置（10-22 Kang：旁邊要寫倒數）
    public static func fuel(_ g: CityGrid) -> String {
        guard let l = g.sevenLeft else { return "油槽・7 天額度讀不到" }
        return "油槽・7 天剩 \(CityRules.gridStep(l) ?? 0)%" + (countdown(g.sevenLeftMin).map { "（\($0)後重置）" } ?? "") + (l <= 5 ? " ⚠" : "")
    }
    /// 頂部「需要你」列的一句
    public static func gridAlert(_ g: CityGrid) -> String {
        g.stage == .blackout ? "停電：AI 額度用完" : "電力吃緊：額度剩不到 5%"
    }
}

// MARK: - 解析

public enum CityParse {
    /// `socketfilterfw --getglobalstate`：「Firewall is enabled. (State = 1)」／「disabled. (State = 0)」／State = 2（擋全部）
    public static func firewall(_ s: String) -> Bool? {
        if let r = s.range(of: #"State\s*=\s*(\d)"#, options: .regularExpression) {
            let n = s[r].last.flatMap { Int(String($0)) }
            return n.map { $0 != 0 }
        }
        let l = s.lowercased()
        if l.contains("disabled") { return false }
        if l.contains("enabled") { return true }
        return nil
    }

    /// `lsof -nP -iTCP -sTCP:LISTEN` → 每個埠一筆（同一埠 IPv4／IPv6 合併；只要有一個綁在非本機位址就算對外）
    public static func listen(_ s: String, knownOpen: [Int: String] = CityRules.knownOpen) -> [ListenPort] {
        var byPort: [Int: ListenPort] = [:]
        for line in s.split(separator: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 9, cols[0] != "COMMAND", let li = cols.lastIndex(where: { $0 == "(LISTEN)" }), li > 0 else { continue }
            let name = String(cols[li - 1])
            guard let colon = name.lastIndex(of: ":"), let port = Int(name[name.index(after: colon)...]) else { continue }
            var host = String(name[..<colon])
            if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
            let loopback = host == "localhost" || host.hasPrefix("127.") || host == "::1" || host == "::ffff:127.0.0.1"
            let proc = String(cols[0]).replacingOccurrences(of: "\\x20", with: " ")
            if var p = byPort[port] {
                if !loopback { p.external = true }
                byPort[port] = p
            } else {
                byPort[port] = ListenPort(port: port, process: proc, external: !loopback, knownOpen: knownOpen[port])
            }
        }
        return byPort.values.sorted { $0.port < $1.port }
    }

    /// ~/.ssh/config 的 Host（不含萬用字元 *、?、!）＋各自的 HostName／Port（同名重複只留第一個）
    public struct SSHHost: Sendable, Equatable {
        public var alias: String
        public var hostName: String
        public var port: Int
    }
    public static func sshHosts(_ s: String) -> [SSHHost] {
        var out: [SSHHost] = []
        var current: [Int] = []           // 目前這個 Host 區塊對到 out 裡的哪幾筆
        var seen = Set<String>()
        for raw in s.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            // 「Key Value」或「Key=Value」
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t=\""))
            switch key {
            case "host":
                current = []
                for a in value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) {
                    guard !a.contains("*"), !a.contains("?"), !a.hasPrefix("!"), seen.insert(a).inserted else { continue }
                    out.append(SSHHost(alias: a, hostName: a, port: 22)); current.append(out.count - 1)
                }
            case "match":
                current = []
            case "hostname":
                for i in current { out[i].hostName = value }
            case "port":
                if let p = Int(value) { for i in current { out[i].port = p } }
            default: break
            }
        }
        return out
    }

    /// cool42 /var/run/cool42/state.json：controlTemp、cpuAvg、level、time（超過 2 分鐘沒更新＝stale）
    public static func cool42(_ d: Data?, now: Date) -> CityPower {
        guard let d, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return CityPower() }
        var p = CityPower(temp: (o["controlTemp"] as? NSNumber)?.doubleValue, cpuAvg: (o["cpuAvg"] as? NSNumber)?.doubleValue, level: o["level"] as? String)
        if let t = o["time"] as? String, let at = ISO8601DateFormatter().date(from: t) { p.stale = now.timeIntervalSince(at) > 120 }
        return p
    }

    /// ~/Library/CloudStorage 底下的資料夾名 → 顯示名（拿掉「-帳號」：GoogleDrive-a@b.com → Google Drive）
    public static func cloudName(_ folder: String) -> String {
        let base = folder.split(separator: "-", maxSplits: 1).first.map(String.init) ?? folder
        switch base.lowercased() {
        case "googledrive": return "Google Drive"
        case "onedrive": return "OneDrive"
        case "dropbox": return "Dropbox"
        case "box": return "Box"
        default:
            // 駝峰拆字：SynologyDrive → Synology Drive
            var s = ""
            for ch in base { if ch.isUppercase, !s.isEmpty, s.last != " " { s.append(" ") }; s.append(ch) }
            return s
        }
    }

    /// 外接碟的可用空間（10-21 實測：FAT32 隨身碟的「重要用途可用」回 0，4 GB 空碟被畫成 100% 滿）：
    /// 重要用途可用讀不到或是 0、但一般可用 > 0 ⇒ 用一般可用
    public static func available(important: Int64?, plain: Int64?) -> Int64 {
        if let i = important, i > 0 { return i }
        return max(plain ?? 0, important ?? 0)
    }

    /// `brctl quota`：「92346786485 bytes of quota remaining in personal account」→ 剩餘 bytes；格式不符＝nil
    public static func brctlQuota(_ s: String) -> Int64? {
        guard let r = s.range(of: #"(\d+)\s+bytes of quota remaining"#, options: .regularExpression) else { return nil }
        return Int64(s[r].prefix { $0.isNumber })
    }

    /// `brctl status` 的一個容器
    public struct BrContainer: Sendable, Equatable {
        public var name: String              // brctl 輸出管線時會把名字遮成 c{1}m.a{3}e.C{7}s，照原樣留著
        public var client: [String]          // client:idle／needs-sync|blocked-app-uninstalled ⋯
        public var lastSync: Date?
        public var caughtUp: Bool
        public var disabled: Bool            // 「SYNC DISABLED (app not installed)」：App 刪掉了，正常，不算錯誤
        public var needsSync: Bool { client.contains("needs-sync") }
        /// 被擋住（App 已刪除的 blocked-app-uninstalled 不算）
        public var blocked: Bool { client.contains { $0.hasPrefix("blocked") && $0 != "blocked-app-uninstalled" } }
    }

    /// 把 `brctl status` 的輸出拆成容器（去掉 ANSI 顏色碼；時間是本機時區「yyyy-MM-dd HH:mm:ss.SSS」）
    public static func brctlStatus(_ raw: String, timeZone: TimeZone = .current) -> (containers: [BrContainer], desktopDocs: Bool?) {
        let s = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        var out: [BrContainer] = []
        var dd: Bool?
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone; f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        for line in s.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix(">>>") {
                if line.contains("SYNC DISABLED"), !out.isEmpty { out[out.count - 1].disabled = true }
                continue
            }
            if line.hasPrefix("Desktop & Documents:") {
                if let r = line.range(of: #"current=(YES|NO)"#, options: .regularExpression) { dd = line[r].hasSuffix("YES") }
                continue
            }
            guard line.hasPrefix("<"), let sp = line.firstIndex(of: " ") else { continue }
            var name = String(line[line.index(after: line.startIndex)..<sp])
            if let b = name.lastIndex(of: "["), name.hasSuffix("]") { name = String(name[..<b]) }
            var client: [String] = []
            if let r = line.range(of: #"client:[^ ]+"#, options: .regularExpression) {
                client = line[r].dropFirst("client:".count).split(separator: "|").map(String.init)
            }
            var last: Date?
            if let r = line.range(of: #"last-sync:\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3}"#, options: .regularExpression) {
                last = f.date(from: String(line[r].dropFirst("last-sync:".count)))
            }
            out.append(BrContainer(name: name, client: client, lastSync: last, caughtUp: line.contains("caught-up"), disabled: false))
        }
        return (out, dd)
    }

    /// 組成 iCloud 狀態：main＝`brctl status com.apple.CloudDocs` 的輸出（只有主容器）、all＝`brctl status` 全部、quota＝`brctl quota`。
    /// 讀不到主容器、也讀不到額度 ⇒ nil（畫面只寫「已連線」）
    public static func cloudSync(quota: String?, main: String?, all: String?) -> CloudSync? {
        let q = quota.flatMap(brctlQuota)
        let m = main.map { brctlStatus($0) }
        let drive = m?.containers.first
        guard q != nil || drive != nil else { return nil }
        var s = CloudSync(remaining: q, driveState: drive.map { $0.client.isEmpty ? "unknown" : $0.client.joined(separator: "|") },
                          lastSync: drive?.lastSync, caughtUp: drive?.caughtUp ?? false, desktopDocs: m?.desktopDocs)
        if let a = all.map({ brctlStatus($0).containers }) {
            let active = a.filter { !$0.disabled && $0.name != drive?.name }
            s.pending = active.filter(\.needsSync).count
            s.blocked = active.filter(\.blocked).count
        }
        return s
    }

    /// 要不要把這個卷當成一個堆場：/Volumes 底下、不是根目錄、不是系統卷（Recovery、Preboot、VM、Update、時光機快照⋯）
    public static func includeVolume(path: String, name: String, isRoot: Bool, browsable: Bool) -> Bool {
        guard !isRoot, browsable, path.hasPrefix("/Volumes/") else { return false }
        let n = name.lowercased()
        let system = ["recovery", "preboot", "vm", "update", "xarts", "iscpreboot", "hardware", "macintosh hd", "macintosh hd - data"]
        if system.contains(n) { return false }
        if n.contains("timemachine") || n.contains("time machine") || n.hasPrefix("com.apple.") || n.contains("backups of") { return false }
        return true
    }

    /// 曾經看過的外接碟名稱：現在插著的接在後面（不重複、不改舊順序）
    public static func rememberDisks(_ known: [String], mounted: [String]) -> [String] {
        var out = known
        for m in mounted where !out.contains(m) { out.append(m) }
        return out
    }

    /// 港口：repo → 最新的遠端 ref 時間；跟上次比變新的 ⇒ 出港。第一次（上次是空的）只當基準，不出港
    public static func departures(old: [String: Date], new: [String: Date]) -> [String] {
        guard !old.isEmpty else { return [] }
        return new.filter { k, t in old[k].map { t > $0 } ?? false }.map(\.key).sorted()
    }
}

// MARK: - 穿插檢查（10-21：堆場旁一坨歪斜貨櫃互相插進對方 ⇒ 城市每個方塊都可以拿來互相比）

/// 一個方塊：中心、長寬高、繞 Y 軸轉的角度（弧度，跟 3D 的 Xf.a 同一個方向）
public struct CityBox: Sendable, Equatable {
    public var center: SIMD3<Float>
    public var size: SIMD3<Float>
    public var yaw: Float
    public init(center: SIMD3<Float>, size: SIMD3<Float>, yaw: Float = 0) { self.center = center; self.size = size; self.yaw = yaw }
    public var rotated: Bool { abs(remainder(yaw, Float.pi / 2)) > 1e-4 }
    /// 水平面上的兩個軸（x、z）
    var axes: (SIMD2<Float>, SIMD2<Float>) {
        let c = cos(yaw), s = sin(yaw)
        return (SIMD2(c, -s), SIMD2(s, c))          // Xf.apply：local x → (c, -s)、local z → (s, c)
    }

    /// 兩個方塊互相插進去多深（公尺；≤0＝沒碰到或只是貼著）。分離軸：上下＋水平面 4 條軸，取最小的重疊量
    public static func penetration(_ a: CityBox, _ b: CityBox) -> Float {
        let dy = min(a.center.y + a.size.y / 2, b.center.y + b.size.y / 2) - max(a.center.y - a.size.y / 2, b.center.y - b.size.y / 2)
        guard dy > 0 else { return dy }
        let (ax, az) = a.axes, (bx, bz) = b.axes
        let d = SIMD2(b.center.x - a.center.x, b.center.z - a.center.z)
        var best = dy
        for n in [ax, az, bx, bz] {
            func r(_ box: CityBox, _ u: SIMD2<Float>, _ w: SIMD2<Float>) -> Float {
                abs(simd_dot(u, n)) * box.size.x / 2 + abs(simd_dot(w, n)) * box.size.z / 2
            }
            let overlap = r(a, ax, az) + r(b, bx, bz) - abs(simd_dot(d, n))
            if overlap <= 0 { return overlap }
            best = min(best, overlap)
        }
        return best
    }
}
