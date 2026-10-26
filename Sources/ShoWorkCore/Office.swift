import Foundation

// 3D 辦公室的資料層（10-20 Kang 拍板）：
//   ① 房間規則＝「固定樓層＋活動區」：~/github-repos 底下最近 30 天有 commit 的 repo 都有固定部門（沒人時暗著），
//      30 天外的專案有 AI 開在那邊時臨時加一個部門。部門位置依名稱排序，不因誰在忙而換位置。
//   ② 入口「前台・保全」：資料來自 wifiwatch（~/.claude/scripts/wifiwatch.sh 採集、wifiwatch.py 分析），
//      名冊 ~/.claude/data/wifiwatch_devices.json、紀錄 ~/.claude/data/wifiwatch.log。
//   ③ 格局（棋盤分區／中庭環狀）與燈光（白天／夜晚／自動）可以切換。
// 這裡只有純邏輯（可測）；讀檔、FSEvents、跑掃描在 ShoWorkAgent。

// MARK: - 常駐專案名冊

/// 一個常駐部門的來源：~/github-repos/<name>，最後一次 commit 的時間
public struct ResidentProject: Sendable, Equatable {
    public var name: String
    public var lastCommit: Date
    public init(name: String, lastCommit: Date) { self.name = name; self.lastCommit = lastCommit }
}

public enum ResidentProjects {
    /// 最近幾天內有 commit 才算常駐
    public static let window: TimeInterval = 30 * 86400
    /// 多久重算一次（10-20：不監看 ~/github-repos——底下 build／node_modules 的變動會產生大量無關事件，
    /// 只掛在看板 15 秒保底 timer 上每 30 分鐘重算一次；啟動時算一次）
    public static let rescanInterval: TimeInterval = 30 * 60

    /// 列出 root 底下（只看第一層）最近 `window` 內有 commit 的 git repo，依名稱排序。
    /// 名稱＝資料夾名，跟 `Board.projectName`（往上找 .git 的資料夾名）算出來的 BoardCard.project 一致。
    /// 不算：符號連結（冷資料搬到 SD 卡的專案，碰它會喚醒外接卡）、`.git` 是檔案的 worktree（ProjectA-w1 這類分身，
    /// 有 AI 開在那邊時會變臨時部門）、從來沒 commit 過的（沒有 reflog 也沒有分支）。不開 git 子行程。
    public static func scan(root: String, now: Date, window: TimeInterval = window) -> [ResidentProject] {
        let fm = FileManager.default
        var out: [ResidentProject] = []
        for name in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where !name.hasPrefix(".") {
            let dir = root + "/" + name
            guard FileStat.lstat(dir)?.isDirectory == true else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir + "/.git", isDirectory: &isDir), isDir.boolValue,
                  let t = lastCommit(gitDir: dir + "/.git"), now.timeIntervalSince(t) <= window else { continue }
            out.append(ResidentProject(name: name, lastCommit: t))
        }
        return out.sorted { order($0.name, $1.name) }
    }

    /// 部門排序：不分大小寫、數字照大小（ProjectA 在 ProjectB 之後）；穩定，不看誰在忙
    public static func order(_ a: String, _ b: String) -> Bool {
        let r = a.localizedStandardCompare(b)
        return r == .orderedSame ? a < b : r == .orderedAscending
    }

    /// 最後一次 commit 的時間：讀 .git/logs/HEAD 尾端（不開 git）。沒有 reflog 就看 refs/heads 底下分支檔的 mtime。
    public static func lastCommit(gitDir: String) -> Date? {
        let log = gitDir + "/logs/HEAD"
        if let h = FileHandle(forReadingAtPath: log) {
            defer { try? h.close() }
            let size = (try? h.seekToEnd()) ?? 0
            // 先讀尾端 64KB；最後幾筆都是 checkout／reset 時往前讀整個檔（上限 4MB）
            for back: UInt64 in [64 << 10, 4 << 20] {
                try? h.seek(toOffset: size > back ? size - back : 0)
                if let t = reflogLastCommit(h.readDataToEndOfFile()) { return t }
                if size <= back { break }
            }
            return nil
        }
        return newestRef(gitDir + "/refs/heads")
    }

    /// reflog 裡算「有 commit」的動作：本機 commit、合併、pull、rebase、cherry-pick、revert、am。
    /// 不算 checkout／reset／branch／clone（只是移動 HEAD，不是有人在這個專案做事）。
    static let commitActions = ["commit", "merge", "pull", "rebase", "cherry-pick", "revert", "am"]

    /// 一行 reflog：`<舊> <新> 名字 <信箱> <時間戳> <時區>\t<動作>: <訊息>`（名字可以有空白）
    public static func reflogLastCommit(_ d: Data) -> Date? {
        for raw in d.split(separator: 0x0A).reversed() {
            let line = String(decoding: raw, as: UTF8.self)
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let head = line[..<tab], msg = line[line.index(after: tab)...]
            let action = msg.prefix { $0 != ":" }.split(separator: " ").first.map(String.init) ?? ""
            guard commitActions.contains(action), let gt = head.range(of: "> ", options: .backwards) else { continue }
            let parts = head[gt.upperBound...].split(separator: " ")
            if let s = parts.first, let ts = Double(s) { return Date(timeIntervalSince1970: ts) }
        }
        return nil
    }

    private static func newestRef(_ dir: String) -> Date? {
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: dir) else { return nil }
        var best: Date?
        while let f = e.nextObject() as? String {
            guard let a = FileStat.lstat(dir + "/" + f), a.isRegular else { continue }
            let m = a.date
            best = max(best ?? m, m)
        }
        return best
    }
}

/// 辦公室裡的一個部門
public struct OfficeDepartment: Sendable, Equatable, Identifiable {
    public var name: String          // ＝BoardCard.project
    public var isResident: Bool      // 常駐（30 天內有 commit）；false＝臨時（有 AI 開在那邊才出現）
    public var isActive: Bool        // 現在有 AI 在（含排隊中的訊息）；沒人時暗著
    public var id: String { name }
    public init(name: String, isResident: Bool, isActive: Bool) { self.name = name; self.isResident = isResident; self.isActive = isActive }
}

public enum OfficeDepartments {
    /// 有序的部門清單：常駐部門照名稱排在前面，臨時部門照名稱接在後面。
    /// 名稱比對不分大小寫（APFS 不分大小寫，cwd 偶爾跟資料夾名大小寫不同）；顯示用常駐名冊的寫法。
    /// 影分身（visiting）不開部門——只是 cd 過去逛一下（跟部門島同一條規則）。
    public static func build(residents: [String], cards: [BoardCard]) -> [OfficeDepartment] {
        var present = Set<String>()
        var tempNames: [String: String] = [:]           // 小寫 → 第一次看到的寫法
        let known = Set(residents.map { $0.lowercased() })
        for c in cards {
            let k = c.project.lowercased()
            present.insert(k)
            if !known.contains(k), tempNames[k] == nil { tempNames[k] = c.project }
        }
        let fixed = residents.map { OfficeDepartment(name: $0, isResident: true, isActive: present.contains($0.lowercased())) }
        let temps = tempNames.values.sorted(by: ResidentProjects.order).map { OfficeDepartment(name: $0, isResident: false, isActive: true) }
        return fixed + temps
    }
}

// MARK: - 前台・保全（wifiwatch）

public enum GuardLevel: String, Sendable, Codable, Comparable {
    case normal, notice, alert

    public var title: String {
        switch self {
        case .normal: "正常"
        case .notice: "注意"
        case .alert: "警示"
        }
    }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
    private var rank: Int { self == .normal ? 0 : self == .notice ? 1 : 2 }
}

/// 要保全注意的一台裝置
public struct GuardDevice: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case new          // 紀錄裡有 NEW、名冊裡還沒命名
        case unnamed      // 名冊裡沒命名
        case unconfirmed  // 名字以 ★ 開頭（wifiwatch 標的「不在你清單上」，你還沒確認）
        case named        // 已命名（只出現在 onlineDevices 清單）
    }
    public var mac: String
    public var ip: String?
    public var vendor: String?
    public var label: String?
    public var kind: Kind
    public var online: Bool          // 最近一次掃描有看到
    public var firstSeen: Date?
    public var hostname: String?
    /// 只看到 IPv6、MAC 又是隨機的（本機管理位元）：多半是家裡手機／平板的隱私位址（10-20 審查：真實名冊裡 3 台都是這種，
    /// 原本會讓保全一直亮紅燈）。陌生人連上 Wi-Fi 會拿 DHCP 的 IPv4，所以這種只算「注意」不算「警示」
    public var privacyOnly: Bool { ip == nil && WifiWatch.isLocallyAdministered(mac) }
    public init(mac: String, ip: String? = nil, vendor: String? = nil, label: String? = nil, kind: Kind, online: Bool, firstSeen: Date? = nil) {
        self.mac = mac; self.ip = ip; self.vendor = vendor; self.label = label; self.kind = kind; self.online = online; self.firstSeen = firstSeen
    }
}

/// 保全看到的 Wi-Fi 狀態。不含「現在幾點」以外會一直變的東西，內容沒變就不重新發布。
public struct GuardStatus: Sendable, Equatable {
    public var hasData = false        // 名冊檔存在、讀得懂
    public var lastScan: Date?        // 上次掃描（名冊裡最新的 last_seen：每次掃描會把在線裝置都蓋成同一個時間）
    public var knownCount = 0         // 名冊裝置數
    public var onlineCount = 0        // 上次掃描在線的
    public var flagged: [GuardDevice] = []   // 未命名／新裝置／★未確認（在線的排前面）
    public var onlineDevices: [GuardDevice] = []   // 上次掃描在線的全部裝置（10-24 Kang：要看在線的是哪些）；依 IP 排
    public var stale = false          // 超過 24 小時沒掃描
    public var level: GuardLevel = .notice
    public var summary = ""           // 一句話（給櫃台螢幕）
    // push 守門（10-22，PushGuard）：最近 24 小時
    public var pushChecked = 0
    public var pushBlocked = 0
    public var pushRecent: [PushEvent] = []    // 新的在前，最多 5 筆
    public init() {}

    /// 把 push 守門的紀錄併進來：擋過金鑰 ⇒ 警示；擋過別的 ⇒ 至少注意
    public mutating func merge(pushes evs: [PushEvent]) {
        pushChecked = evs.count
        pushBlocked = evs.filter { $0.verdict == .block }.count
        pushRecent = Array(evs.prefix(5))
        if evs.contains(where: { $0.secret }) { level = .alert }
        else if pushBlocked > 0, level < .notice { level = .notice }
        if pushChecked > 0 {
            let p = "24 小時內檢查 \(pushChecked) 次 push" + (pushBlocked > 0 ? "，擋下 \(pushBlocked) 次" : "，都沒問題")
            summary = summary.isEmpty ? p : summary + "；" + p
        }
    }
}

public enum WifiWatch {
    /// 多久沒掃描算「很久沒掃描」
    public static let staleAfter: TimeInterval = 24 * 3600
    /// last_seen 跟上次掃描差多少以內算「那次在線」（同一次掃描寫的是同一個時間，留一點餘裕）
    public static let onlineSlack: TimeInterval = 120

    /// 解析名冊（JSON：MAC → {first_seen, label, vendor, last_seen, last_ip, hostname?}，時間是本機時間、沒有時區）
    /// 與紀錄（`YYYY-MM-DD HH:MM:SS  NEW  <ip 或 (僅 IPv6)>  <MAC>  <廠商>`；# 開頭是人工註記）。
    /// 紀錄裡 NEW、名冊卻已經沒有的 MAC 不算（被 --forget 掉的，例如 09-22 IPv6 測試假警報）。
    public static func parse(devices: Data?, log: Data?, now: Date, timeZone: TimeZone = .current) -> GuardStatus {
        var s = GuardStatus()
        guard let devices, let db = (try? JSONSerialization.jsonObject(with: devices)) as? [String: [String: Any]] else {
            s.level = .notice; s.summary = "還沒掃描過 Wi-Fi"
            return s
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone; f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        s.hasData = true
        s.knownCount = db.count
        let seen = db.mapValues { ($0["last_seen"] as? String).flatMap(f.date) }
        s.lastScan = seen.values.compactMap { $0 }.max()
        func online(_ mac: String) -> Bool {
            guard let t = seen[mac] ?? nil, let last = s.lastScan else { return false }
            return last.timeIntervalSince(t) <= onlineSlack
        }
        s.onlineCount = db.keys.filter(online).count

        // 紀錄的 NEW 行：MAC → 第一次被報的時間
        var newAt: [String: Date] = [:]
        let lf = DateFormatter()
        lf.locale = Locale(identifier: "en_US_POSIX"); lf.timeZone = timeZone; lf.dateFormat = "yyyy-MM-dd HH:mm:ss"
        for raw in (log ?? Data()).split(separator: 0x0A) {
            let line = String(decoding: raw, as: UTF8.self)
            guard !line.hasPrefix("#"), line.count > 19, let t = lf.date(from: String(line.prefix(19))) else { continue }
            let rest = line.dropFirst(19).split(separator: " ", omittingEmptySubsequences: true)
            guard rest.first == "NEW", let mac = rest.first(where: { isMAC($0) }).map({ $0.lowercased() }) else { continue }
            if newAt[mac] == nil { newAt[mac] = t }
        }

        for (mac, r) in db {
            let label = (r["label"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let kind: GuardDevice.Kind
            if label.isEmpty { kind = newAt[mac] != nil ? .new : .unnamed }
            else if label.hasPrefix("★") { kind = .unconfirmed }
            else { kind = .named }
            var d = GuardDevice(mac: mac, ip: r["last_ip"] as? String, vendor: r["vendor"] as? String,
                                label: label.isEmpty ? nil : label, kind: kind, online: online(mac),
                                firstSeen: (r["first_seen"] as? String).flatMap(f.date) ?? newAt[mac])
            d.hostname = r["hostname"] as? String
            if d.online { s.onlineDevices.append(d) }
            if kind != .named { s.flagged.append(d) }
        }
        // IP 依數字排（.9 在 .10 前）；只有 IPv6 的排最後
        func ipKey(_ d: GuardDevice) -> [Int] { d.ip.map { $0.split(separator: ".").compactMap { Int($0) } } ?? [999] }
        s.onlineDevices.sort { ipKey($0) == ipKey($1) ? $0.mac < $1.mac : ipKey($0).lexicographicallyPrecedes(ipKey($1)) }
        s.flagged.sort { ($0.online ? 0 : 1, $0.ip ?? "~", $0.mac) < ($1.online ? 0 : 1, $1.ip ?? "~", $1.mac) }

        s.stale = s.lastScan.map { now.timeIntervalSince($0) > staleAfter } ?? true
        // 警示：沒命名的裝置上次掃描還在線上（有陌生人連著你的 Wi-Fi）。注意：很久沒掃描、或有待確認的裝置。
        if s.flagged.contains(where: { $0.online && $0.kind != .unconfirmed && !$0.privacyOnly }) { s.level = .alert }
        else if s.stale || !s.flagged.isEmpty { s.level = .notice }
        else { s.level = .normal }

        var parts: [String] = []
        if s.lastScan == nil { parts.append("還沒掃描過 Wi-Fi") }
        else if s.stale { parts.append("很久沒掃描了") }
        parts.append("上次在線 \(s.onlineCount) 台／名冊 \(s.knownCount) 台")
        let strangers = s.flagged.filter { $0.kind != .unconfirmed }.count
        let pending = s.flagged.count - strangers
        let privacy = s.flagged.filter { $0.kind != .unconfirmed && $0.privacyOnly }.count
        if strangers > 0 { parts.append("\(strangers) 台沒命名" + (privacy > 0 ? "（\(privacy) 台只有 IPv6 隨機位址）" : "")) }
        if pending > 0 { parts.append("\(pending) 台待確認") }
        s.summary = parts.joined(separator: "，")
        return s
    }

    /// MAC 第一個位元組的「本機管理」位元（0x02）：手機 Wi-Fi 隱私位址、虛擬網卡都會設
    public static func isLocallyAdministered(_ mac: String) -> Bool {
        guard let b = UInt8(mac.prefix(2), radix: 16) else { return false }
        return b & 0x02 != 0
    }

    static func isMAC(_ s: Substring) -> Bool {
        let p = s.split(separator: ":", omittingEmptySubsequences: false)
        return p.count == 6 && p.allSatisfy { (1...2).contains($0.count) && $0.allSatisfy(\.isHexDigit) }
    }
}

/// 「立即掃描」：背景跑 wifiwatch.sh（不帶參數＝掃一次），同一時間只跑一個；結束後名冊檔變了，FSEvents 會叫看板重讀。
/// runner 可注入（測試不准真的掃網路）。
public final class GuardScanner: @unchecked Sendable {
    public typealias Runner = @Sendable (_ script: String) -> Int32
    /// 定時巡邏的間隔
    public static let patrolInterval: TimeInterval = 30 * 60

    public let script: String
    private let runner: Runner
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var running = false
    private var lastStart: Date?

    public init(script: String, queue: DispatchQueue = DispatchQueue(label: "showork.guard"), runner: @escaping Runner) {
        self.script = script; self.queue = queue; self.runner = runner
    }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    public var lastStarted: Date? { lock.lock(); defer { lock.unlock() }; return lastStart }

    /// 開始掃一次；已經在跑就不重複開（回傳 false）。done 在背景佇列上被叫，帶回結束碼。
    @discardableResult
    public func scan(now: Date = Date(), done: (@Sendable (Int32) -> Void)? = nil) -> Bool {
        lock.lock()
        if running { lock.unlock(); return false }
        running = true; lastStart = now
        lock.unlock()
        let script = self.script, runner = self.runner
        queue.async { [weak self] in
            let code = runner(script)
            self?.lock.lock(); self?.running = false; self?.lock.unlock()
            done?(code)
        }
        return true
    }

    /// 巡邏到時間了沒：開著、沒在跑、上次掃描（名冊時間）和上次自己開始的時間都超過間隔。
    /// 用「上次自己開始」擋住：掃描失敗、名冊時間沒更新時不會每 15 秒重掃一次。
    public static func patrolDue(enabled: Bool, running: Bool, lastScan: Date?, lastStarted: Date?, now: Date,
                                 interval: TimeInterval = patrolInterval) -> Bool {
        guard enabled, !running else { return false }
        if let t = lastScan, now.timeIntervalSince(t) < interval { return false }
        if let t = lastStarted, now.timeIntervalSince(t) < interval { return false }
        return true
    }
}

// MARK: - 格局與燈光設定

/// 辦公室格局（10-20：兩種都要、可切換）
public enum OfficeLayout: String, Sendable, CaseIterable {
    case grid   // A 棋盤分區：部門排兩區，中央走道放咖啡吧／會議桌／隊長台
    case ring   // C 中庭環狀：部門圍一圈朝中央公共區

    public var title: String { self == .grid ? "棋盤分區" : "中庭環狀" }
}

/// 燈光
/// 畫面風格（10-22 Kang：等角微縮模型、藍圖線框兩種都要試）：只換鏡頭與後製，模型不變
public enum OfficeStyle: String, Sendable, CaseIterable {
    case voxel, diorama, blueprint
    public var title: String {
        switch self {
        case .voxel: "體素（原本）"
        case .diorama: "微縮模型（等角＋移軸）"
        case .blueprint: "藍圖（深藍底、發光線條）"
        }
    }
}

public enum OfficeLighting: String, Sendable, CaseIterable {
    case day, night, auto

    public var title: String {
        switch self {
        case .day: "白天"
        case .night: "夜晚"
        case .auto: "自動"
        }
    }

    /// 自動：跟台北的真實太陽（10-21 日出日落，Solar.swift）；白天／夜晚固定＝改版前的兩組燈光
    public func sun(at date: Date) -> SunSample { Solar.position(at: date) }

    /// 這個時間點的天色與燈光
    public func look(at date: Date) -> SkyLook {
        switch self {
        case .day: return .day
        case .night: return .night
        case .auto: return SkyLook.at(sun(at: date))
        }
    }

    /// 自動：太陽在地平線下夠深（暗度過半，約仰角 −1.5° 以下）算夜晚
    public func isNight(at date: Date, calendar: Calendar = .current) -> Bool { look(at: date).isNight }

    /// 標籤文字：自動＝「自動・清晨／日出／白天／傍晚／日落／黃昏／夜晚」
    public func label(at date: Date) -> String {
        self == .auto ? "自動・\(SkyLook.phaseTitle(sun(at: date)))" : title
    }

    /// 天色會變的仰角範圍（這段每分鐘更新一次）；白天只有太陽方向在動（每 5 分鐘）；夜晚整段不變
    public static let changingBand = -13.0...23.0

    /// 自動模式下一次要重算燈光的時間（畫面排一次性的 sleep，不輪詢）：
    /// 晨昏那段每 60 秒、白天每 5 分鐘（主光東升西落）、夜晚睡到天快亮（仰角回到 −13°）。白天／夜晚固定就回 nil
    public func nextChange(after date: Date, calendar: Calendar = .current) -> Date? {
        guard self == .auto else { return nil }
        let e = Solar.position(at: date).elevation
        if Self.changingBand.contains(e) { return date.addingTimeInterval(60) }
        if e > Self.changingBand.upperBound { return date.addingTimeInterval(300) }
        // 夜晚：每 2 分鐘往後找第一個進入晨昏帶的時間（最多 24 小時）
        var t = date
        for _ in 0..<720 {
            t = t.addingTimeInterval(120)
            if Solar.position(at: t).elevation >= Self.changingBand.lowerBound { return t }
        }
        return date.addingTimeInterval(3600)
    }
}

/// 辦公室的設定（UserDefaults suite ai.okle42.showork；agent 與測試共用同一組鍵）
public struct OfficePrefs {
    public static let suite = "ai.okle42.showork"
    public static let layoutKey = "office.layout"          // grid｜ring，預設 grid
    public static let styleKey = "office.style"            // voxel｜diorama｜blueprint，預設 voxel
    public static let lightingKey = "office.lighting"      // day｜night｜auto，預設 auto
    public static let guardPatrolKey = "office.guardPatrol"   // Bool，預設關
    public static let weatherKey = "office.weather"        // Bool，預設開（10-21 台北真實天氣，Weather.swift）
    public static let weatherPlacesKey = "office.weatherPlaces"  // [WeatherSite] JSON，沒存＝只看台北（10-25，每台電腦自己選）
    public static let weatherSitesKey = "office.weatherSites"    // 舊格式（10-25 早上 ff3526e）：[String] 預設地點名；讀到就轉成上面的新格式

    public let store: UserDefaults
    public init(store: UserDefaults? = nil) { self.store = store ?? UserDefaults(suiteName: Self.suite) ?? .standard }

    public var layout: OfficeLayout {
        get { store.string(forKey: Self.layoutKey).flatMap(OfficeLayout.init(rawValue:)) ?? .grid }
        nonmutating set { store.set(newValue.rawValue, forKey: Self.layoutKey) }
    }
    public var lighting: OfficeLighting {
        get { store.string(forKey: Self.lightingKey).flatMap(OfficeLighting.init(rawValue:)) ?? .auto }
        nonmutating set { store.set(newValue.rawValue, forKey: Self.lightingKey) }
    }
    public var guardPatrol: Bool {
        get { store.object(forKey: Self.guardPatrolKey) as? Bool ?? false }
        nonmutating set { store.set(newValue, forKey: Self.guardPatrolKey) }
    }
    /// 現在是不是夜晚（照目前的燈光設定）
    public func isNight(at date: Date = Date(), calendar: Calendar = .current) -> Bool { lighting.isNight(at: date, calendar: calendar) }
}
