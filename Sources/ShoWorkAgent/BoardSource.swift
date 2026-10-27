import Foundation
import Combine
import ShoWorkCore

// 戰情中心的資料層：每 1.5 秒讀一次本機的 Claude Code 狀態，組成看板。
// 隊伍資料夾和信箱會被 Claude Code 刪掉／清空，所以看到的隊員進出、訊息、換欄都記進 history.jsonl，
// 之後重開也拿得回來。全部唯讀，不寫 ~/.claude 底下任何東西。

enum BoardPaths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static var claude: String { ProcessInfo.processInfo.environment["SHOWORK_CLAUDE_DIR"] ?? home + "/.claude" }
    static var dir: URL { Paths.supportDir.appendingPathComponent("board", isDirectory: true) }
    static var history: URL { dir.appendingPathComponent("history.jsonl") }
    /// 常駐部門從這裡找 repo（10-20 3D 辦公室；SHOWORK_REPOS_DIR 給測試換）
    static var repos: String { ProcessInfo.processInfo.environment["SHOWORK_REPOS_DIR"] ?? home + "/github-repos" }
    /// wifiwatch 的名冊與紀錄（前台・保全；SHOWORK_WIFIWATCH_DIR 給測試換）
    static var wifiwatchDir: String { ProcessInfo.processInfo.environment["SHOWORK_WIFIWATCH_DIR"] ?? claude + "/data" }
    static var wifiwatchDevices: String { wifiwatchDir + "/wifiwatch_devices.json" }
    static var wifiwatchLog: String { wifiwatchDir + "/wifiwatch.log" }
    /// 「立即掃描」跑的腳本（SHOWORK_WIFIWATCH_SCRIPT 給測試換成假的，測試不准真的掃網路）
    static var wifiwatchScript: String { ProcessInfo.processInfo.environment["SHOWORK_WIFIWATCH_SCRIPT"] ?? claude + "/scripts/wifiwatch.sh" }
}

/// 從磁碟讀一次（背景執行緒可用；不碰 UI）
final class BoardReader: @unchecked Sendable {
    private var transcriptCache: [String: (mtime: Date, size: Int, info: TranscriptInfo)] = [:]
    /// 尾端解析的接續狀態：解析到哪個位元組、從上次整段重解析以來又餵了多少（超過 tailBytes 就整段重來，維持「只看尾端」的語意）
    private var tailParse: [String: (offset: Int, fed: Int, parser: TranscriptInfo.Parser)] = [:]
    /// 量測（SHOWORK_BOARD_TRACE）：整段重解析／增量的次數與位元組
    private(set) var parseStats = (full: 0, incr: 0, bytes: 0)
    private let fm = FileManager.default
    static let tailBytes = 512 * 1024

    struct Snapshot: Sendable {
        var sessions: [SessionRecord] = []
        var transcripts: [String: TranscriptInfo] = [:]
        var glows: [Int32: WorkState] = [:]
        var teams: [TeamConfig] = []
        var inbox: [TeamMessage] = []
        var reports: [String: SelfReport] = [:]
        var nicknames: [String: Nickname] = [:]
        var reviews: [String: Review] = [:]
        var decisions: [String: Decision] = [:]
        var rateLimits: RateLimits?
        var runs: [RunProgress] = []          // 背景長工作的即時進度（run/progress/*.json；10-26）
        var contexts: [String: ContextUse] = [:]
        var captain: CaptainRecord?
        var tasks: [CaptainTask] = []
        var residents: [ResidentProject] = []        // 3D 辦公室常駐部門（10-20）
        var guardStatus = GuardStatus()              // 前台・保全（10-20）
        var permits: [String: PermitRequest] = [:]   // 等你按允許的（10-21）
        var handovers: [String: HandoverRecord] = [:] // 自動交接（Handover.swift）：舊 sid → 紀錄
        var captainThread: [CaptainLine] = []        // 隊長對話（10-22 第 3 步）
        var sessionThread: [CaptainLine] = []        // 右側對話窗格正在看的那個 AI（10-25）
    }

    /// 隊長對話：只在隊長的對話紀錄變了才重讀尾端（1.5MB，讀圖的行很大）
    private var threadCache: [Bool: (stamp: String, lines: [CaptainLine])] = [:]   // full → 快取（隊長一份、右側窗格一份）
    func captainThread(_ cap: CaptainRecord?, sessions: [SessionRecord]) -> [CaptainLine] {
        guard let cap else { threadCache[false] = nil; return [] }
        return thread(cap.sessionId, sessions: sessions, full: false)
    }

    /// 右側對話窗格要看哪個 session（畫面在主執行緒設、讀檔在 queue 上讀）
    private let watchLock = NSLock()
    private var watchingSid: String?
    var watching: String? {
        get { watchLock.lock(); defer { watchLock.unlock() }; return watchingSid }
        set { watchLock.lock(); watchingSid = newValue; watchLock.unlock() }
    }
    private var pathCache: [String: String] = [:]

    /// 某個 session 的對話（jsonl 尾端 1.5MB）；檔案沒變就用快取
    func thread(_ sid: String, sessions: [SessionRecord], full: Bool) -> [CaptainLine] {
        guard let path = transcriptPath(sid, sessions: sessions) else { threadCache[full] = nil; return [] }
        let st = sid + "/" + (FileStat.lstat(path)?.stamp ?? "-")
        if let c = threadCache[full], c.stamp == st { return c.lines }
        guard let h = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 1_500_000 ? size - 1_500_000 : 0)
        let lines = CaptainThread.parse(h.readDataToEndOfFile(), full: full)
        threadCache[full] = (st, lines)
        return lines
    }

    /// 對話紀錄的路徑：名冊裡有就照專案目錄算；沒有（背景 session 不在名冊）就到 projects/ 底下找一次記起來
    private func transcriptPath(_ sid: String, sessions: [SessionRecord]) -> String? {
        if let r = sessions.first(where: { $0.sessionId == sid }) { return "\(BoardPaths.claude)/projects/\(r.projectSlug)/\(sid).jsonl" }
        if let p = pathCache[sid], FileManager.default.fileExists(atPath: p) { return p }
        let base = BoardPaths.claude + "/projects"
        for d in (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? [] {
            let p = "\(base)/\(d)/\(sid).jsonl"
            if FileManager.default.fileExists(atPath: p) { pathCache[sid] = p; return p }
        }
        return nil
    }

    // 10-20 3D 辦公室：常駐名冊每 30 分鐘重算一次（read() 至少每 15 秒被保底 timer 叫一次，這裡只比時間，不另開 timer）
    private var residents: [ResidentProject] = []
    private var residentsAt: Date?
    func residentProjects(now: Date = Date()) -> [ResidentProject] {
        if let t = residentsAt, now.timeIntervalSince(t) < ResidentProjects.rescanInterval, now >= t { return residents }
        residents = ResidentProjects.scan(root: BoardPaths.repos, now: now)
        residentsAt = now
        return residents
    }

    /// 保全：名冊／紀錄的 mtime＋大小沒變、也還沒跨過「24 小時沒掃描」那條線，就沿用上次的結果（不重新解析）
    private var guardStamp = "", guardCached: GuardStatus?
    func guardStatus(now: Date = Date()) -> GuardStatus {
        func stamp(_ p: String) -> String {
            FileStat.lstat(p)?.stamp ?? "-"
        }
        // push 守門的紀錄也算（10-22）；每小時換一次 stamp，讓 24 小時前的紀錄自己掉出去
        let st = stamp(BoardPaths.wifiwatchDevices) + "/" + stamp(BoardPaths.wifiwatchLog) + "/" + stamp(PushGuard.logURL.path)
            + "/" + String(Int(now.timeIntervalSince1970 / 3600))
        if st == guardStamp, let c = guardCached,
           c.stale || c.lastScan.map({ now.timeIntervalSince($0) <= WifiWatch.staleAfter }) == true { return c }
        var g = WifiWatch.parse(devices: fm.contents(atPath: BoardPaths.wifiwatchDevices), log: fm.contents(atPath: BoardPaths.wifiwatchLog), now: now)
        g.merge(pushes: PushGuard.recent(fm.contents(atPath: PushGuard.logURL.path), since: now.addingTimeInterval(-86400)))
        guardStamp = st; guardCached = g
        return g
    }

    func read() -> Snapshot {
        var s = Snapshot()
        let sdir = BoardPaths.claude + "/sessions"
        for f in (try? fm.contentsOfDirectory(atPath: sdir)) ?? [] where f.hasSuffix(".json") {
            guard let d = fm.contents(atPath: sdir + "/" + f), let r = SessionRecord.decode(d),
                  r.kind != "background", kill(r.pid, 0) == 0 || errno == EPERM else { continue }   // 行程不在＝殘留檔
            s.sessions.append(r)
        }
        for r in s.sessions { s.transcripts[r.sessionId] = transcript(r) }
        // 行程已結束的 session：快取一起放掉（token 去重的 id 集合會跟著對話長大；10-20 審查）
        let alive = Set(s.sessions.map(\.sessionId))
        if tokenCache.keys.contains(where: { !alive.contains($0) }) {
            tokenCache = tokenCache.filter { alive.contains($0.key) }
            cwdCache = cwdCache.filter { alive.contains($0.key) }
            transcriptCache = transcriptCache.filter { alive.contains($0.key) }
            tailParse = tailParse.filter { alive.contains($0.key) }
        }
        s.glows = Self.glows()
        let tdir = BoardPaths.claude + "/teams"
        for team in (try? fm.contentsOfDirectory(atPath: tdir)) ?? [] {
            guard let d = fm.contents(atPath: "\(tdir)/\(team)/config.json"), let c = TeamConfig.decode(d) else { continue }
            s.teams.append(c)
            let ib = "\(tdir)/\(team)/inboxes"
            for f in (try? fm.contentsOfDirectory(atPath: ib)) ?? [] where f.hasSuffix(".json") {
                if let d = fm.contents(atPath: ib + "/" + f) { s.inbox += TeamMessage.decodeInbox(d, owner: String(f.dropLast(5))) }
            }
        }
        s.reports = BoardStore.readAll("cards", as: SelfReport.self)
        s.nicknames = BoardStore.readAll("names", as: Nickname.self)
        s.reviews = BoardStore.readAll("reviews", as: Review.self)
        s.decisions = BoardStore.readAll("decisions", as: Decision.self)
        s.permits = Permit.pending()
        s.handovers = Dictionary(Handover.all().map { ($0.sid, $0) }, uniquingKeysWith: { $1 })
        s.rateLimits = BoardStore.rateLimits()
        s.runs = RunProgress.load(dir: ProcessInfo.processInfo.environment["SHOWORK_RUN_PROGRESS"] ?? BoardPaths.claude + "/run/progress")
        s.captain = CaptainStore.captain()
        s.tasks = CaptainStore.tasks()
        s.captainThread = captainThread(s.captain, sessions: s.sessions)
        if let w = watching { s.sessionThread = thread(w, sessions: s.sessions, full: true) } else { threadCache[true] = nil }
        for r in s.sessions {
            let f = "\(BoardPaths.claude)/cache/ctx/\(r.sessionId).json"
            if let d = fm.contents(atPath: f), let c = ContextUse.parse(d) { s.contexts[r.sessionId] = c }
        }
        s.residents = residentProjects()
        s.guardStatus = guardStatus()
        return s
    }

    /// 最近做事的地方：尾端 512KB 常常只剩十幾筆（讀圖的行很大），娃娃住哪會亂跳 ⇒ 另外記，第一次往回讀 8MB，之後只讀新增的
    private var cwdCache: [String: (offset: Int, cwds: [CwdMark])] = [:]
    private func workCwds(_ sid: String, _ h: FileHandle, size: Int) -> [CwdMark] {
        var c = cwdCache[sid] ?? (max(0, size - 8 << 20), [])
        if size < c.offset { c = (max(0, size - 8 << 20), []) }          // 檔案被改寫
        try? h.seek(toOffset: UInt64(c.offset))
        let d = h.readDataToEndOfFile()
        let end = (d.lastIndex(of: 0x0A).map { $0 - d.startIndex + 1 }) ?? 0   // 最後一行可能還沒寫完，下次再讀
        c.cwds = Array((c.cwds + TranscriptInfo.workCwds(d.prefix(end))).suffix(TranscriptInfo.cwdWindow))
        c.offset += end
        cwdCache[sid] = c
        return c.cwds
    }

    /// 累計 token：第一次從檔頭掃到尾（512KB 一塊，不一次載入整個檔），之後只讀新增的完整行（10-20）
    /// 10-20 審查：2MB 一塊時第一次讀的記憶體峰值多 34MB（93 vs 59MB），512KB 只多 10MB，時間多約 0.3 秒（只有第一次）
    private var tokenCache: [String: (offset: Int, tally: TokenTally)] = [:]
    static let tokenChunk = 512 << 10
    static let asyncMaxAge: TimeInterval = 12 * 3600
    private func tokens(_ sid: String, _ h: FileHandle, size: Int) -> TokenTally {
        var c = tokenCache[sid] ?? (0, TokenTally())
        if size < c.offset { c = (0, TokenTally()) }                       // 檔案被改寫
        try? h.seek(toOffset: UInt64(c.offset))
        var carry = Data()
        var more = true
        while more {
            autoreleasepool {                                               // 背景執行緒沒有 run loop：每塊自己放掉，不然整個檔都留在記憶體
                let chunk = h.readData(ofLength: Self.tokenChunk)
                if chunk.isEmpty { more = false; return }
                carry.append(chunk)
                guard let nl = carry.lastIndex(of: 0x0A) else { return }    // 一行比一塊還長：再讀
                let end = nl - carry.startIndex + 1
                c.tally.consume(carry.prefix(end))
                c.offset += end
                carry = Data(carry.dropFirst(end))
            }
        }
        tokenCache[sid] = c                                                 // 最後一行沒寫完的下次再讀
        return c.tally
    }

    /// 對話紀錄只在檔案變了才重讀尾端
    private func transcript(_ r: SessionRecord) -> TranscriptInfo {
        let path = "\(BoardPaths.claude)/projects/\(r.projectSlug)/\(r.sessionId).jsonl"
        guard let st = FileStat.lstat(path) else { return TranscriptInfo() }
        let m = st.date, size = st.size
        if let c = transcriptCache[r.sessionId], c.mtime == m, c.size == size { return c.info }
        guard let h = FileHandle(forReadingAtPath: path) else { return TranscriptInfo() }
        defer { try? h.close() }
        var info: TranscriptInfo
        if var tp = tailParse[r.sessionId], size >= tp.offset, tp.fed < Self.tailBytes {
            // 只讀新增的完整行（最後一行可能還沒寫完，下次再讀）
            try? h.seek(toOffset: UInt64(tp.offset))
            let d = h.readDataToEndOfFile()
            let end = (d.lastIndex(of: 0x0A).map { $0 - d.startIndex + 1 }) ?? 0
            tp.parser.feed(d.prefix(end))
            tp.offset += end; tp.fed += end
            tailParse[r.sessionId] = tp
            info = tp.parser.info
            parseStats.incr += 1; parseStats.bytes += end
        } else {
            let start = max(0, size - Self.tailBytes)
            try? h.seek(toOffset: UInt64(start))
            let d = h.readDataToEndOfFile()
            let end = (d.lastIndex(of: 0x0A).map { $0 - d.startIndex + 1 }) ?? 0
            var p = TranscriptInfo.Parser()
            p.feed(d.prefix(end))
            tailParse[r.sessionId] = (start + end, 0, p)
            info = p.info
            parseStats.full += 1; parseStats.bytes += end
        }
        if info.title == nil, let old = transcriptCache[r.sessionId]?.info.title { info.title = old }   // 標題在尾端外就沿用
        info.recentWorkCwds = workCwds(r.sessionId, h, size: size)
        let tally = tokens(r.sessionId, h, size: size)
        info.tokens = tally.usage
        // 背景 agent 以全檔追蹤為準（尾端看不到啟動那行也算）；尾端有的資訊比較完整（subagent_type）就用尾端的。
        // 超過 12 小時沒收到完成通知的當作已經不在（session 被強制結束就永遠收不到通知）（10-20 審查）
        let cutoff = Date().addingTimeInterval(-Self.asyncMaxAge)
        info.asyncAgents = tally.asyncAgents.filter { ($0.launchedAt ?? .distantFuture) > cutoff }
            .map { a in info.asyncAgents.first { $0.id == a.id } ?? a }
        transcriptCache[r.sessionId] = (m, size, info)
        return info
    }

    /// ShoWork 自己的光暈狀態（Engine 每次 render 都會存 state.json）
    static func glows() -> [Int32: WorkState] {
        struct Saved: Decodable { let state: WorkState; let pid: Int32 }
        guard let d = try? Data(contentsOf: Paths.supportDir.appendingPathComponent("state.json")),
              let s = try? JSONDecoder().decode([Saved].self, from: d) else { return [:] }
        var out: [Int32: WorkState] = [:]
        for x in s { out[x.pid] = StateMachine.windowState([out[x.pid] ?? .idle, x.state]) }
        return out
    }
}

/// 盯著看板的資料來源，有變才叫 refresh（FSEvents，0.3 秒內的變動併成一次）。
/// 看板自己會寫的檔（roster.json、history.jsonl）不算，不然會自己叫醒自己、一直轉。
final class BoardWatcher: @unchecked Sendable {
    static let trace = ProcessInfo.processInfo.environment["SHOWORK_BOARD_TRACE"] != nil
    private var stream: FSEventStreamRef?
    private let onChange: @Sendable (Bool) -> Void           // true＝有對話紀錄以外的變動（要馬上讀）
    private let claude: String, support: String
    private let wifi: Set<String>          // wifiwatch 名冊與紀錄（10-20 前台・保全）

    init(onChange: @escaping @Sendable (Bool) -> Void) {
        self.onChange = onChange
        claude = Self.real(BoardPaths.claude)
        support = Self.real(Paths.supportDir.path)
        let wdir = Self.real(BoardPaths.wifiwatchDir)
        wifi = [wdir + "/wifiwatch_devices.json", wdir + "/wifiwatch.log"]
        let roots = [claude, support] as CFArray
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, n, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<BoardWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            me.handle(Array(list.prefix(n)))
        }
        stream = FSEventStreamCreate(nil, cb, &ctx, roots, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    /// 真正的路徑（FSEvents 回報的是這個）。10-20：NSString.resolvingSymlinksInPath 會把 /private/tmp 改成 /tmp，
    /// 測試資料夾放在 /private/tmp 底下時事件路徑對不上、一個都不認；改用 realpath
    static func real(_ p: String) -> String {
        guard let r = realpath(p, nil) else { return (p as NSString).resolvingSymlinksInPath }
        defer { free(r) }
        return String(cString: r)
    }

    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }

    /// 這個路徑的變動要不要讀一輪
    func relevant(_ p: String) -> Bool {
        // wifiwatch.py 先寫 wifiwatch_devices.json.tmp 再改名：只認正式檔名（改名那筆事件會帶正式檔名）
        if wifi.contains(p) { return true }
        if p.hasPrefix(claude + "/") {
            let r = p.dropFirst(claude.count + 1)
            if r.hasPrefix("sessions/") || r.hasPrefix("teams/") || r.hasPrefix("cache/ctx/") || r == "cache/rate_limits.json" { return true }
            if r.hasPrefix("run/progress/") && r.hasSuffix(".json") { return true }   // 背景工作進度（10-26）
            return r.hasPrefix("projects/") && r.hasSuffix(".jsonl") && !r.contains("/subagents/")
        }
        if p.hasPrefix(support + "/") {
            let r = p.dropFirst(support.count + 1)
            // 原子寫入會先寫 roster.json.sb-xxxx 再改名（10-20 實測：沒擋到就自己叫醒自己，27 秒刷 73 次）
            if r.hasPrefix("board/roster.json") || r.hasPrefix("board/history.jsonl") || r.contains(".sb-") || r.hasSuffix(".tmp") { return false }
            // 10-20 科技大樓：樓層號名冊、樓層主題快取、AI 呼叫紀錄都是看板自己寫的，不算（不然寫檔叫醒自己）
            if r.hasPrefix("board/tower.json") || r.hasPrefix("board/themes/") || r.hasPrefix("board/decor_ledger.json") { return false }
            return r == "state.json" || r.hasPrefix("board/")
        }
        return false
    }

    private func handle(_ paths: [String]) {
        let hit = paths.filter(relevant)
        guard !hit.isEmpty else { return }
        if Self.trace { print("board fsevent", hit.count, hit.first ?? ""); fflush(stdout) }
        // 只有對話紀錄（projects/*.jsonl）、ctx 快取在變 ⇒ 不急（視窗沒人看時看板放慢到 idleGap）
        let urgent = hit.contains { p in !(p.hasPrefix(claude + "/projects/") || p.hasPrefix(claude + "/cache/ctx/")) }
        onChange(urgent)
    }
}

/// 看板的狀態，畫面訂閱它
@MainActor
final class BoardModel: ObservableObject {
    static let shared = BoardModel()
    @Published private(set) var cards: [BoardCard] = []
    /// 10-20：不再 @Published（沒有畫面在看；每 1.5 秒觸發整個看板 SwiftUI 重新排版，3D 辦公室停止渲染後這是閒置 CPU 的大宗，約 3%）
    private(set) var updated = Date()
    @Published private(set) var rateLimits: RateLimits?
    @Published private(set) var runs: [RunProgress] = []          // 背景長工作的即時進度（名字下方的進度條；10-26）
    @Published private(set) var reviewing = Set<String>()
    /// 3D 辦公室的部門（常駐照名稱＋臨時接在後面；10-20）。內容變了才發布
    @Published private(set) var departments: [OfficeDepartment] = []
    /// 前台・保全看到的 Wi-Fi 狀態（10-20）。內容變了才發布
    @Published private(set) var guardStatus = GuardStatus()
    @Published private(set) var captainThread: [CaptainLine] = []   // 隊長對話（10-22 第 3 步）
    @Published private(set) var sessionThread: [CaptainLine] = []   // 右側對話窗格（10-25）：watching 那個 session 的對話
    /// 右側對話窗格開始／停止看某個 session（nil＝回到隊長）；馬上讀一次
    func watch(_ sid: String?) {
        guard reader.watching != sid else { return }
        reader.watching = sid
        sessionThread = []
        refresh()
    }
    @Published private(set) var captainTasks: [CaptainTask] = []    // 還沒結的派工單
    /// 「立即掃描」正在跑
    @Published private(set) var guardScanning = false
    /// 讀過第一輪了沒（3D 辦公室：讀到之前卡片是空的，不能當成「第一次載入」；10-20）
    @Published private(set) var loaded = false
    /// 科技大樓（10-20 第 2 棒）：由下往上的樓層（大廳、閒置薄層、專案樓層、頂樓）。內容變了才發布
    @Published private(set) var tower = TowerPlan()
    /// 上一次 tower 變動時的搬家清單（第 3 棒播「飄出→升降→插回」；跟 tower 同一次發布）
    private(set) var towerMoves: [TowerMove] = []
    /// 每個專案（小寫）的樓層主題：快取＋本地預設＋測試覆寫。內容變了才發布
    @Published private(set) var decor: [String: FloorDecor] = [:]
    /// 角色閒晃：每個人待哪、這次新出發的行程。內容變了才發布
    @Published private(set) var wander = WanderPlan()
    /// 外部空間城市（10-21）：CityMonitor 在背景收，跟上次不一樣才交過來
    @Published private(set) var city = CityState()
    func setCity(_ c: CityState) { if c != city { city = c } }
    /// 畫面告訴資料層「看得到」（第 3 棒接 occlusion：被蓋住／縮小／辦公室沒開就設 false）。
    /// false 時不出發新行程、進行中的直接落地；改值會馬上重排一次（不等下次刷新）
    var wanderVisible = BoardWindow.testMode {
        didSet { if wanderVisible != oldValue { replanWander() } }
    }
    private var towerReg = TowerStore.load()

    private let reader = BoardReader()
    private let queue = DispatchQueue(label: "showork.board")
    private var timer: Timer?
    private var lastColumn: [String: BoardColumn] = [:]
    private var lastMembers: [String: Set<String>] = [:]          // team name → teammates
    private var seenMsg = Set<String>()
    private var archived: [String: [TeamMessage]] = [:]          // lead sessionId → 看過的訊息（信箱清空後還留著）
    private var archivedMates: [String: [String]] = [:]          // lead sessionId → 出現過的隊員

    // 10-20：原本每 1.5 秒整輪讀檔（閒置 CPU 約 2.3% 都是它）。改成事件驅動：FSEvents 看到相關檔案變了才讀；
    // 另外每 15 秒保底讀一次，給「看時間」的判斷用（超過 10 分鐘沒動靜＝卡住、行程死掉留下的殘留檔）。
    static let fallbackInterval: TimeInterval = 15
    private var watcher: BoardWatcher?
    private var inFlight = false, again = false
    var refreshCount = 0                                  // 測試用：SHOWORK_BOARD_TRACE=1 會印出來

    func start() {
        guard timer == nil else { return }
        loadHistory()
        refresh()
        HeatGate.shared.check()
        CityMonitor.shared.tick(force: true)
        watcher = BoardWatcher { urgent in MainActor.assumeIsolated { BoardModel.shared.refresh(urgent: urgent) } }
        timer = Timer.scheduledTimer(withTimeInterval: Self.fallbackInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(); self?.patrol(); HeatGate.shared.check(); CityMonitor.shared.tick() }
        }
    }

    /// 同一時間只讀一輪；讀的時候又有事件進來，讀完再補一輪
    /// 10-21 CPU 突波：好幾個 AI 同時在工作時，對話紀錄每秒寫好幾次，FSEvents（0.3 秒合併）一路叫醒 ⇒ 一秒讀 2–3 輪、
    /// 每輪都重建看板、跑一次 3D 更新。兩輪之間至少隔 1 秒（中間進來的事件併成一次，延後到 1 秒到時補讀；原本輪詢就是 1.5 秒）
    static let minGap: TimeInterval = 1.0

    // 刷新統計（10-24 Kang「先量再做」）：每 5 分鐘一行 BOARD stats 進 agent.log（次數、讀檔／套用平均與最慢、視窗開著的比例）
    private var stat = (n: 0, read: 0.0, readMax: 0.0, apply: 0.0, applyMax: 0.0, shown: 0, since: Date())
    func noteRefresh(read: Double, apply: Double) {
        stat.n += 1; stat.read += read; stat.readMax = max(stat.readMax, read); stat.apply += apply; stat.applyMax = max(stat.applyMax, apply)
        if BoardWindow.shared.onScreen { stat.shown += 1 }
        let span = Date().timeIntervalSince(stat.since)
        guard span >= 300 else { return }
        let n = Double(stat.n)
        Log.note(String(format: "BOARD stats %.0f 秒 刷新 %d 次（%.1f 次/分）讀檔 平均 %.1f／最慢 %.0f ms 套用 平均 %.1f／最慢 %.0f ms 視窗開著 %d%%",
                        span, stat.n, n / span * 60, stat.read / n, stat.readMax, stat.apply / n, stat.applyMax, stat.shown * 100 / max(1, stat.n)))
        stat = (0, 0, 0, 0, 0, 0, Date())
    }
    /// 視窗沒人看、而且只有對話紀錄在變時的間隔（10-24：session 多時對話紀錄一直寫，每秒整套重讀是閒置 CPU 的大宗）。
    /// 卡片、收件匣、派工單、權限、session 進出這些「urgent」變動照樣 minGap 內處理：發光走 socket 不經過這裡，轉隊長要 1 秒內
    static let idleGap: TimeInterval = 4.0
    private var lastStart = Date.distantPast
    private var dueAt: Date?
    private var againUrgent = false
    func refresh(urgent: Bool = true) {
        if inFlight { again = true; againUrgent = againUrgent || urgent; return }
        let gap = urgent || BoardWindow.shared.onScreen ? Self.minGap : Self.idleGap
        let at = lastStart.addingTimeInterval(gap)
        if at > Date() {
            if let d = dueAt, d <= at { return }                         // 已經排了更早的一次
            dueAt = at
            DispatchQueue.main.asyncAfter(deadline: .now() + at.timeIntervalSinceNow) {
                MainActor.assumeIsolated {
                    let m = BoardModel.shared
                    guard let d = m.dueAt, Date() >= d.addingTimeInterval(-0.02) else { return }   // 被更早的那次取代了
                    m.dueAt = nil; m.refresh()
                }
            }
            return
        }
        dueAt = nil
        lastStart = Date()
        inFlight = true
        refreshCount += 1
        let t0 = Date(), n = refreshCount
        queue.async { [reader] in
            let snap = reader.read()
            let readMs = Date().timeIntervalSince(t0) * 1000
            if BoardWatcher.trace {
                let ps = reader.parseStats
                print(String(format: "board refresh %d read %.1fms parse full=%d incr=%d bytes=%d", n, Date().timeIntervalSince(t0) * 1000, ps.full, ps.incr, ps.bytes)); fflush(stdout)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let m = BoardModel.shared
                    let a0 = Date()
                    m.apply(snap)
                    m.noteRefresh(read: readMs, apply: Date().timeIntervalSince(a0) * 1000)
                    m.inFlight = false
                    if m.again { let u = m.againUrgent; m.again = false; m.againUrgent = false; m.refresh(urgent: u) }
                }
            }
        }
    }

    private func apply(_ s: BoardReader.Snapshot) {
        record(s)
        let fm = FileManager.default
        var cards = Board.build(sessions: s.sessions, transcripts: s.transcripts, glows: s.glows, teams: s.teams,
                                inbox: s.inbox, reports: s.reports, reviews: s.reviews, decisions: s.decisions,
                                contexts: s.contexts, nicknames: s.nicknames,
                                now: Date(), home: BoardPaths.home,
                                isRepo: { fm.fileExists(atPath: $0 + "/.git") })
        for i in cards.indices where !cards[i].id.contains("#") {
            let sid = cards[i].sessionId
            if let old = archived[sid] { cards[i].messages = Array(old.suffix(5)) }
            if cards[i].teammates.isEmpty, let m = archivedMates[sid] { cards[i].teammates = m.map { $0 + "（已離隊）" } }
            cards[i].permit = s.permits[sid]
            cards[i].handover = s.handovers[sid]?.label
        }
        let captain = s.captain.flatMap { r in s.sessions.contains { $0.sessionId == r.sessionId } ? r.sessionId : nil }
        cards = Captain.annotate(cards, captain: captain, tasks: s.tasks)
        relayCards(s, captain: captain, cards: cards)
        let roster = Captain.roster(cards, captain: captain, now: Date())
        queue.async { CaptainStore.saveRoster(roster) }
        captainAlarm(roster, captain: captain, now: Date())
        for c in cards where lastColumn[c.id] != c.column {
            if lastColumn[c.id] != nil || !c.id.contains("#") {
                append(["ev": "column", "id": c.id, "project": c.project, "title": c.title, "column": c.column.rawValue, "reason": c.reason])
            }
            lastColumn[c.id] = c.column
        }
        if cards != self.cards { self.cards = cards }
        Reviewer.shared.consider(cards, reviews: s.reviews)
        CtxGuard.shared.check(cards)
        HandoverClear.shared.check(cards, records: s.handovers, captain: captain)
        TaskRouter.shared.check(s.tasks)
        let rv = Set(cards.map(\.sessionId).filter { Reviewer.shared.isRunning($0) })
        if rv != reviewing { reviewing = rv }
        if s.rateLimits != rateLimits { rateLimits = s.rateLimits }
        if s.runs != runs { runs = s.runs }
        let deps = OfficeDepartments.build(residents: s.residents.map(\.name), cards: cards)
        if deps != departments { departments = deps }
        if s.guardStatus != guardStatus { guardStatus = s.guardStatus }
        if s.captainThread != captainThread { captainThread = s.captainThread }
        if reader.watching != nil, s.sessionThread != sessionThread { sessionThread = s.sessionThread }
        // 隊長面板的派工單：還在做的（3 天內有動靜）＋要你看的（24 小時內）；卡住的排最前面
        let now = Date()
        let rank: (CaptainTask.State) -> Int = { $0 == .blocked ? 0 : $0 == .review ? 1 : 2 }
        let open = s.tasks.filter { t in
            let age = now.timeIntervalSince(t.updatedAt)
            return (t.state.open && age < 3 * 86400) || (t.state == .review && age < 86400)
        }.sorted { (rank($0.state), $1.updatedAt) < (rank($1.state), $0.updatedAt) }
        if open != captainTasks { captainTasks = open }
        applyTower(deps, cards: cards)
        updated = Date()
        if !loaded { loaded = true }
    }

    // MARK: 工作卡片自動轉送隊長（派工 T1021174030；規則在 ShoWorkCore/CardRelay.swift）

    private var relayState = CardRelay.State()
    private func relayCards(_ s: BoardReader.Snapshot, captain: String?, cards: [BoardCard]) {
        guard Engine.current != nil,                                   // 只有正式 agent 送（測試視窗、截圖不送）
              UserDefaults(suiteName: OfficePrefs.suite)?.object(forKey: CardRelay.settingKey) as? Bool ?? true else { return }
        let project = Dictionary(cards.map { ($0.sessionId, $0.project) }, uniquingKeysWith: { a, _ in a })
        let out = CardRelay.plan(reports: s.reports, captain: captain, captainLive: captain != nil, state: &relayState) { sid, r in
            CardRelay.text(name: s.nicknames[sid]?.name ?? project[sid] ?? String(sid.prefix(8)), project: project[sid], report: r)
        }
        let starts = Set(out.filter { s.reports[$0.sessionId]?.isStart == true }.map(\.sessionId))
        if !out.isEmpty, let cap = captain {
            queue.async {                                               // 不阻塞：發卡的 session 不等，看板也不等
                guard let to = Peer.find(cap) else { return }
                for o in out {
                    let r = Peer.send(to: to, text: o.text, fromName: "AI工作戰情中心")
                    Log.note("RELAY card \(o.sessionId.prefix(8)) → \(to.name ?? cap) \(r)")
                    // 開工卡送到了 ⇒ 收件匣那張標成已送（T1024033803 ④）
                    if case .success = r, starts.contains(o.sessionId) {
                        for var i in CaptainInbox.all() where i.kind == .start && i.sid == o.sessionId && !i.delivered { i.delivered = true; CaptainInbox.save(i) }
                    }
                }
            }
        }
        flushNotices(captain: captain)
    }

    // MARK: 隊長連動（T1024033803）：不擋的動作預告合併送、隊長鬧鐘

    /// 收件匣裡還沒送的預告：同一 session 安靜 5 秒（最多等 30 秒）合成一則送隊長
    /// 收件匣資料夾沒變、上次也沒有等著送的預告 ⇒ 不讀檔（每次刷新都會問）
    nonisolated(unsafe) private static var inboxSeen: (stamp: String, open: Bool)?
    private func flushNotices(captain: String?) {
        guard Engine.current != nil, let cap = captain else { return }
        queue.async {
            let stamp = FileStat.lstat(CaptainInbox.dir.path)?.stamp ?? "none"
            if let s = Self.inboxSeen, s.stamp == stamp, !s.open { return }
            let items = CaptainInbox.all(), now = Date()
            Self.inboxSeen = (stamp, items.contains { $0.kind == .notice && !$0.delivered && now.timeIntervalSince($0.at) < CaptainLink.staleAfter })
            let due = CaptainLink.dueNotices(items, now: now)
            guard !due.isEmpty, let to = Peer.find(cap) else { return }
            for g in due {
                let r = Peer.send(to: to, text: CaptainLink.noticeText(g), fromName: "AI工作戰情中心（動作預告）")
                Log.note("PREVIEW \(g[0].name) ×\(g.count) → \(to.name ?? cap) \(r)")
                if case .success = r { for var i in g { i.delivered = true; CaptainInbox.save(i) } }
            }
        }
    }

    /// 隊長鬧鐘：每 captain.alarmMinutes 分鐘（預設 30）送【巡檢時間】；名冊跟上次一樣只送「無變化」；沒有隊長不送
    private var alarmAt = Date()            // 看板啟動算起，不一開就送
    private var alarmSig: String?
    private func captainAlarm(_ roster: Roster, captain: String?, now: Date) {
        guard Engine.current != nil, let cap = captain else { return }
        let min = UserDefaults(suiteName: OfficePrefs.suite)?.object(forKey: CaptainLink.alarmKey) as? Double ?? 30
        guard min > 0, now.timeIntervalSince(alarmAt) >= min * 60 else { return }
        alarmAt = now
        let (full, sig) = CaptainLink.alarm(roster, pending: CaptainInbox.pending(now: now).count, now: now)
        let text = sig == alarmSig ? CaptainLink.alarmUnchanged(crew: roster.entries.filter { !$0.captain }.count) : full
        alarmSig = sig
        queue.async {
            CaptainInbox.prune(now: now)
            guard let to = Peer.find(cap) else { return }
            Log.note("ALARM → \(to.name ?? cap) \(Peer.send(to: to, text: text, fromName: "AI工作戰情中心（巡檢）"))")
        }
    }

    // MARK: 科技大樓（10-20 第 2 棒）

    /// 樓層、主題、閒晃：都掛在這次刷新上，不另開 timer。名冊只有正式 agent 會存檔（測試視窗用假資料時不能污染你的樓層號）
    private func applyTower(_ deps: [OfficeDepartment], cards: [BoardCard]) {
        let now = Date()
        let accents = decor.mapValues(\.accentColor)
        let (plan, dirty) = TowerPlan.build(departments: deps, cards: cards, registry: &towerReg,
                                            usage: { TowerStore.usage(departments: deps, cards: cards) }, accents: accents, now: now)
        if dirty, TowerDecor.shared.official { TowerStore.save(towerReg) }
        if plan != tower {
            towerMoves = TowerPlan.moves(from: tower, to: plan)
            tower = plan
            scheduleDemotion(now: now)
        }
        decorChanged()
        TowerDecor.shared.consider(cards: cards, tower: plan)
        GraphSource.shared.consider(tower: plan, cards: cards)          // 地下室神經網路（10-22）：自己節流，10 分鐘內同一組專案不重排
        replanWander(now: now)
    }

    /// 2 小時降樓：排一次性的 asyncAfter 到最近那個降樓時間（不輪詢；15 秒保底刷新也會順便算到）
    private var demotionAt: Date?
    private func scheduleDemotion(now: Date) {
        guard let t = towerReg.nextDemotion(now: now), demotionAt != t else { return }
        demotionAt = t
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, t.timeIntervalSince(now) + 1)) {
            MainActor.assumeIsolated { BoardModel.shared.demotionAt = nil; BoardModel.shared.refresh() }
        }
    }

    /// 主題快取（或 AI 剛回來）→ 發布：快取有的用快取，沒有的先用專案名的本地評分（不阻塞畫面），測試覆寫最後蓋上去
    func decorChanged() {
        var d = TowerDecor.shared.picker.all()
        for f in tower.projectFloors {
            guard let name = f.project else { continue }
            let k = name.lowercased()
            // 10-20 UI/UX 優化 §4.3：用「專案身分」（專案名＋README 第一段）校正——AI 挑的主題不在身分前 2 名就不採用、識別色鎖主題色。
            // 身分每個專案只算一次（README 讀一次）；正式 agent 校正後的結果寫回快取，立即生效
            let id = TowerDecor.shared.identity(name, cards: cards.filter { $0.project.caseInsensitiveCompare(name) == .orderedSame })
            if let c = d[k] {
                let r = DecorPolicy.reconcile(c, identity: id)
                if r != c { d[k] = r; if TowerDecor.shared.official { TowerDecor.shared.picker.store(name, r) } }
            } else {
                d[k] = FloorDecor.local(id, now: Date(timeIntervalSince1970: 0), reason: "還沒判斷，先用專案身分")
            }
        }
        for (k, v) in TowerStore.themeOverrides() { d[k] = v }
        if d != decor { decor = d }
    }

    /// 你按的「重新裝潢」（第 3 棒接右鍵選單）：回傳給 toast 的一句話
    func redecorate(_ project: String) -> String { TowerDecor.shared.redecorate(project, cards: cards) }

    private func replanWander(now: Date = Date()) {
        let w = WanderPlanner.plan(people: TowerStore.people(cards, tower: tower), tower: tower, previous: wander.states,
                                   now: now, visible: wanderVisible, mode: TowerStore.wanderMode,
                                   rain: OfficeWeather.shared.current?.kind.isWet ?? false, cars: wander.cars)
        if w != wander { wander = w }
    }

    // MARK: B1 交流板：10-27 起不再叫醒 B1 閒置的人（T1027193007），改在收尾提示裡順便留（ShoWorkCore/B1Talk.swift）

    // MARK: 前台・保全（10-20）

    /// 立即掃描（你按的，或定時巡邏）：背景跑 wifiwatch.sh；同時只跑一個。名冊寫好後 FSEvents 會叫 refresh，這裡結束時也補一次
    @discardableResult
    func guardScan() -> Bool {
        let ok = BoardActions.guardScanner.scan { code in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                Log.note("GUARD scan done code=\(code)")
                BoardModel.shared.guardScanning = false
                BoardModel.shared.refresh()
            } }
        }
        if ok { guardScanning = true; Log.note("GUARD scan start \(BoardActions.guardScanner.script)") }
        return ok
    }

    /// 定時巡邏：掛在 15 秒保底 timer 上，每 30 分鐘最多一次。只有正式 agent 會巡（測試視窗不動手、不掃網路）
    private func patrol() {
        guard Engine.current != nil else { return }
        let sc = BoardActions.guardScanner
        if GuardScanner.patrolDue(enabled: OfficePrefs().guardPatrol, running: sc.isRunning,
                                  lastScan: guardStatus.lastScan, lastStarted: sc.lastStarted, now: Date()) {
            guardScan()
        }
    }

    /// 隊員進出、新訊息：Claude Code 很快就會刪掉，看到就記
    private func record(_ s: BoardReader.Snapshot) {
        for t in s.teams {
            let now = Set(t.teammates.map(\.name)), was = lastMembers[t.name] ?? []
            for n in now.subtracting(was) {
                append(["ev": "join", "team": t.name, "lead": t.leadSessionId ?? "", "name": n])
                if let l = t.leadSessionId, !(archivedMates[l] ?? []).contains(n) { archivedMates[l, default: []].append(n) }
            }
            for n in was.subtracting(now) { append(["ev": "leave", "team": t.name, "name": n]) }
            lastMembers[t.name] = now
            for m in s.inbox where !seenMsg.contains(m.key) && (now.contains(m.from) || now.contains(m.to ?? "") || m.to == "team-lead") {
                seenMsg.insert(m.key)
                if let l = t.leadSessionId { archived[l, default: []].append(m) }
                append(["ev": "message", "team": t.name, "lead": t.leadSessionId ?? "", "from": m.from, "to": m.to ?? "",
                        "summary": m.summary ?? "", "text": m.text, "ts": m.timestamp ?? "", "key": m.key])
            }
        }
    }

    func append(_ o: [String: String]) {
        var o = o; o["at"] = ISO8601DateFormatter().string(from: Date())
        guard var d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return }
        d.append(0x0A)
        try? FileManager.default.createDirectory(at: BoardPaths.dir, withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: BoardPaths.history) { h.seekToEndOfFile(); h.write(d); try? h.close() }
        else { try? d.write(to: BoardPaths.history) }
    }

    private func loadHistory() {
        guard let d = try? Data(contentsOf: BoardPaths.history) else { return }
        for line in d.split(separator: 0x0A) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: String] else { continue }
            switch o["ev"] {
            case "message":
                guard let k = o["key"], let l = o["lead"], !seenMsg.contains(k) else { continue }
                seenMsg.insert(k)
                archived[l, default: []].append(TeamMessage(from: o["from"] ?? "", text: o["text"] ?? "", summary: o["summary"],
                                                            timestamp: o["ts"], msg_id: k, to: o["to"]))
            case "join":
                if let l = o["lead"], let n = o["name"], !(archivedMates[l] ?? []).contains(n) { archivedMates[l, default: []].append(n) }
            default: break
            }
        }
    }
}
