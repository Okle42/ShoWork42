import AppKit
import Network
import ShoWorkCore

// 外部空間城市的資料收集（10-21）。全部在背景 queue 跑，不新增常駐 Timer：
//   掛在看板 15 秒保底 timer 上（BoardModel.start 的 timer 叫 tick()），每一類自己比時間決定要不要做：
//     cool42 狀態檔   每次 tick（讀一個小檔；溫度差 2°C 以上、等級或煙量變了才算變）
//     磁碟            每 60 秒，外加系統掛載／卸載通知（事件驅動）
//     ssh 伺服器      每 60 秒對每個 Host 的 22 埠（或 config 寫的 Port）做一次 2 秒逾時的 TCP connect（只連一個埠，不掃描）
//     GitHub 港口     每 60 秒 stat ~/github-repos/*/.git/refs/remotes/origin 底下的檔案＋packed-refs 的 mtime
//     雲端            每 5 分鐘：iCloud 跑 brctl quota／brctl status（各 10 秒逾時；剩餘額度、主容器同步狀態、卡住的容器）；
//                     其他 ~/Library/CloudStorage 資料夾只看在不在（File Provider 沒給一般程式讀同步進度）
//     防火牆＋城門    每 5 分鐘跑 socketfilterfw --getglobalstate、lsof -nP -iTCP -sTCP:LISTEN
//   結果組成 CityState，跟上次不一樣才交給 BoardModel 發布（畫面沒變就不重建、不重畫）。
// 測試：SHOWORK_CITY_DEMO=1 換成示範值（含各種警示）；SHOWORK_CITY=off 整個不收、不畫。

enum CityPaths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static var sshConfig: String { ProcessInfo.processInfo.environment["SHOWORK_SSH_CONFIG"] ?? home + "/.ssh/config" }
    static var iCloud: String { home + "/Library/Mobile Documents" }
    static var cloudStorage: String { home + "/Library/CloudStorage" }
}

final class CityMonitor: @unchecked Sendable {
    static let shared = CityMonitor()
    static let off = ProcessInfo.processInfo.environment["SHOWORK_CITY"] == "off"
    static let demo = ProcessInfo.processInfo.environment["SHOWORK_CITY_DEMO"] != nil
    static let trace = ProcessInfo.processInfo.environment["SHOWORK_CITY_TRACE"] != nil
    static let knownKey = "city.knownDisks"
    static let seenKey = "city.diskSeen"          // 外接碟名稱 → 最後一次看到插著的時間（拔掉後懸停卡顯示）
    /// --board-window 測試視窗（不寫回設定）；BoardWindow.testMode 在主執行緒上，這裡在背景 queue 讀不到
    static let testWindow = CommandLine.arguments.contains("--board-window")
    private static let demoShipAt = Date()
    static let suite = "ai.okle42.showork"

    // 背景 queue 上的狀態（只在 queue 上讀寫）
    private let queue = DispatchQueue(label: "showork.city", qos: .utility)
    private var state = CityState()
    private var lastDisk = Date.distantPast, lastServer = Date.distantPast, lastPort = Date.distantPast
    private var lastCloud = Date.distantPast, lastWall = Date.distantPast
    private var refs: [String: Date] = [:]
    private var known: [String] = []
    private var seen: [String: Date] = [:]
    /// 懸停卡要的最新細節（含不發布的：伺服器延遲、檢查時間）。主執行緒讀、背景 queue 寫，用鎖
    private let lock = NSLock()
    private var _latest = CityState()
    var latest: CityState { lock.lock(); defer { lock.unlock() }; return _latest }
    private func setLatest(_ s: CityState) { lock.lock(); _latest = s; lock.unlock() }
    private var started = false
    private var lastMounted: [String] = []
    private var publishedOnce = false

    private init() {}

    /// 看板 timer（15 秒）叫：每一類自己比時間；跑完有變才發布
    func tick(force: Bool = false) {
        guard !Self.off else { return }
        queue.async { [self] in
            if !started {
                started = true
                known = UserDefaults(suiteName: Self.suite)?.stringArray(forKey: Self.knownKey) ?? []
                let raw = UserDefaults(suiteName: Self.suite)?.dictionary(forKey: Self.seenKey) as? [String: Double] ?? [:]
                seen = raw.mapValues { Date(timeIntervalSince1970: $0) }
                DispatchQueue.main.async { Self.watchMounts() }
            }
            if Self.demo { let d = Self.demoState(); setLatest(d); publish(d); return }
            let now = Date()
            var s = state
            s.power = power(old: s.power, now: now)
            s.grid = grid(old: s.grid, now: now)
            if force || now.timeIntervalSince(lastDisk) >= 60 { lastDisk = now; s.disks = disks() }
            if force || now.timeIntervalSince(lastCloud) >= 300 { lastCloud = now; s.clouds = clouds(now: now) }
            if force || now.timeIntervalSince(lastWall) >= 300 { lastWall = now; s.firewall = firewall(now: now) }
            if force || now.timeIntervalSince(lastPort) >= 60 {
                lastPort = now
                let t0 = DispatchTime.now()
                s = port(s, now: now)
                if Self.trace { print("city port scan \((DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000) ms repos=\(s.repos)"); fflush(stdout) }
            }
            // 船只留 30 秒（夠畫面看到一次）
            s.ships.removeAll { now.timeIntervalSince($0.at) > 30 }
            publish(s)
            if force || now.timeIntervalSince(lastServer) >= 60 {
                lastServer = now
                checkServers(now: now)
            }
        }
    }

    /// 掛載／卸載：馬上重看磁碟
    func disksChanged() {
        guard !Self.off, !Self.demo else { return }
        queue.async { [self] in
            var s = state; s.disks = disks(); lastDisk = Date()
            publish(s)
        }
    }

    private func publish(_ s: CityState) {
        setLatest(s)
        guard s != state || !publishedOnce else { return }
        publishedOnce = true
        state = s
        if Self.trace { print("city publish disks=\(s.disks.count) clouds=\(s.clouds.count) servers=\(s.servers.map { "\($0.alias):\($0.online.map { $0 ? "on" : "off" } ?? "?")" }) fw=\(s.firewall.enabled.map { "\($0)" } ?? "?") ports=\(s.firewall.ports.count) power=\(s.power.temp.map { Int($0) } ?? -1) ships=\(s.ships.map(\.repo)) alerts=\(s.alerts.count)"); fflush(stdout) }
        DispatchQueue.main.async { MainActor.assumeIsolated { BoardModel.shared.setCity(s) } }
    }

    @MainActor private static func watchMounts() {
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { _ in CityMonitor.shared.disksChanged() }
        }
    }

    // MARK: 電廠（cool42）

    private func power(old: CityPower, now: Date) -> CityPower {
        let p = CityParse.cool42(FileManager.default.contents(atPath: ProcessInfo.processInfo.environment["SHOWORK_COOL42_STATE"] ?? "/var/run/cool42/state.json"), now: now)
        return CityRules.powerChanged(old, p) ? p : old
    }

    // MARK: 電廠＝AI 額度（statusLine 存的 rate_limits.json；每次 tick 讀一個小檔，換格才算變）
    // 測試：SHOWORK_CITY_GRID=dim|flicker|blackout 換成假數字

    private func grid(old: CityGrid, now: Date) -> CityGrid {
        let g = Self.fakeGrid(now: now) ?? CityRules.grid(BoardStore.rateLimits(), now: now)
        return CityRules.gridChanged(old, g) ? g : old
    }

    static func fakeGrid(now: Date) -> CityGrid? {
        guard let v = ProcessInfo.processInfo.environment["SHOWORK_CITY_GRID"] else { return nil }
        let five: Double = ["dim": 86, "flicker": 97, "blackout": 100][v] ?? 40
        let r = RateLimits(fiveHour: .init(used: five, resetsAt: now.addingTimeInterval(80 * 60)),
                           sevenDay: .init(used: 58, resetsAt: now.addingTimeInterval(3 * 86400)))
        return CityRules.grid(r, now: now)
    }

    // MARK: 磁碟（URLResourceKey，不跑 df）

    private func disks() -> [CityDisk] {
        var out: [CityDisk] = []
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeAvailableCapacityKey, .volumeIsRootFileSystemKey, .volumeIsBrowsableKey, .volumeLocalizedFormatDescriptionKey]
        func disk(_ u: URL, name: String, isInt: Bool) -> CityDisk {
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { return CityDisk(name: name, isInternal: isInt, mountPath: u.path) }
            let plain = Int64(v.volumeAvailableCapacity ?? 0)
            // 10-21：FAT32 隨身碟的 important usage 回 0（空碟被畫成 100% 滿）⇒ CityParse.available 改用一般可用
            return CityDisk(name: name, isInternal: isInt, total: Int64(v.volumeTotalCapacity ?? 0),
                            available: CityParse.available(important: v.volumeAvailableCapacityForImportantUsage, plain: plain),
                            availablePlain: plain, format: v.volumeLocalizedFormatDescription, mountPath: u.path)
        }
        // 內建碟：根目錄（資料卷跟系統卷同一個 APFS 容器，用 important usage 才是你能用的空間）
        out.append(disk(URL(fileURLWithPath: "/"), name: "Data", isInt: true))
        var mounted: [String] = []
        for u in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
            let v = try? u.resourceValues(forKeys: Set(keys))
            let name = v?.volumeName ?? u.lastPathComponent
            guard CityParse.includeVolume(path: u.path, name: name, isRoot: v?.volumeIsRootFileSystem ?? false, browsable: v?.volumeIsBrowsable ?? true) else { continue }
            out.append(disk(u, name: name, isInt: false))
            mounted.append(name)
        }
        // 最後看到的時間：插著的每次更新（記憶體），插拔名單變了才寫回設定（不每分鐘寫）
        for n in mounted { seen[n] = Date() }
        if lastMounted != mounted {
            lastMounted = mounted
            if !Self.testWindow { UserDefaults(suiteName: Self.suite)?.set(seen.mapValues { $0.timeIntervalSince1970 }, forKey: Self.seenKey) }
        }
        let merged = CityParse.rememberDisks(known, mounted: mounted)
        if merged != known {
            known = merged
            // 測試視窗不寫回你的設定
            if !Self.testWindow { UserDefaults(suiteName: Self.suite)?.set(merged, forKey: Self.knownKey) }
        }
        for n in known where !mounted.contains(n) { out.append(CityDisk(name: n, isInternal: false, mounted: false, lastSeen: seen[n])) }
        return out
    }

    // MARK: 雲端（10-21：iCloud 用 brctl 讀得到剩餘額度與同步狀態；其他雲端只知道資料夾掛著）
    // 不讀 ~/Library/Mobile Documents 裡面的檔案（du 會碰到 iCloud Drive 的檔案，可能跳「存取 iCloud Drive」的隱私權限視窗）

    private func clouds(now: Date) -> [CityCloud] {
        var out: [CityCloud] = []
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: CityPaths.iCloud, isDirectory: &isDir), isDir.boolValue {
            let br = "/usr/bin/brctl"
            let sync = CityParse.cloudSync(quota: Self.run(br, ["quota"]), main: Self.run(br, ["status", "com.apple.CloudDocs"]),
                                           all: Self.run(br, ["status"]))
            out.append(CityCloud(name: "iCloud Drive", isICloud: true, sync: sync, checkedAt: now))
        }
        for f in ((try? fm.contentsOfDirectory(atPath: CityPaths.cloudStorage)) ?? []).sorted() where !f.hasPrefix(".") {
            let n = CityParse.cloudName(f)
            if !out.contains(where: { $0.name == n }) { out.append(CityCloud(name: n, checkedAt: now)) }
        }
        return out
    }

    // MARK: 防火牆＋城門（每 5 分鐘）

    private func firewall(now: Date) -> CityFirewall {
        let fw = Self.run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"])
        let ls = Self.run("/usr/sbin/lsof", ["+c0", "-nP", "-iTCP", "-sTCP:LISTEN"])   // +c0：程式名不截在 9 個字
        return CityFirewall(enabled: fw.flatMap(CityParse.firewall), ports: ls.map { CityParse.listen($0) } ?? [], checkedAt: now)
    }

    /// 跑一個系統指令（10 秒沒結束就砍）；失敗＝nil
    static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: killer)
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return String(data: d, encoding: .utf8)
    }

    // MARK: 港口（GitHub）

    private func port(_ s0: CityState, now: Date) -> CityState {
        var s = s0
        let fm = FileManager.default
        let root = BoardPaths.repos
        var cur: [String: Date] = [:]
        for name in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where !name.hasPrefix(".") {
            let dir = root + "/" + name
            // 符號連結（SD 卡冷資料）不碰：不為了看 mtime 去喚醒外接碟
            guard FileStat.lstat(dir)?.isDirectory == true else { continue }
            let git = dir + "/.git"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: git, isDirectory: &isDir), isDir.boolValue else { continue }
            var latest: Date?
            func see(_ p: String) {
                if let m = FileStat.lstat(p)?.date { latest = max(latest ?? m, m) }
            }
            see(git + "/packed-refs")
            let origin = git + "/refs/remotes/origin"
            // 一次拿 mtime（getattrlistbulk），不逐檔 stat（10-21 實測 25 個 repo 逐檔 50 ms）
            if let e = fm.enumerator(at: URL(fileURLWithPath: origin), includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
                for case let u as URL in e {
                    if let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate { latest = max(latest ?? m, m) }
                }
            }
            if let latest { cur[name] = latest }
        }
        for r in CityParse.departures(old: refs, new: cur) { s.ships.append(CityShip(repo: r, at: now)) }
        refs = cur
        s.repos = cur.count
        s.recent = cur.sorted { $0.value > $1.value }.prefix(5).map { CityShip(repo: $0.key, at: $0.value) }
        return s
    }

    // MARK: ssh 伺服器（每 60 秒一個埠的 TCP connect，2 秒逾時）

    private func checkServers(now: Date) {
        let hosts = CityParse.sshHosts((try? String(contentsOfFile: CityPaths.sshConfig, encoding: .utf8)) ?? "")
        // 名單變了（新增／刪掉 Host）先發布「檢查中」
        var s = state
        let old = Dictionary(s.servers.map { ($0.alias, $0) }, uniquingKeysWith: { a, _ in a })
        s.servers = hosts.map { h in
            var v = old[h.alias] ?? CityServer(alias: h.alias)
            v.hostName = h.hostName; v.port = h.port
            return v
        }
        publish(s)
        for h in hosts {
            let t0 = DispatchTime.now()
            Self.probe(host: h.hostName, port: h.port) { [self] ok in
                let ms = Int((DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000)
                queue.async { [self] in
                    var s = state
                    guard let i = s.servers.firstIndex(where: { $0.alias == h.alias }) else { return }
                    let at = Date()
                    s.servers[i].online = ok
                    s.servers[i].checkedAt = at
                    if ok { s.servers[i].lastOnline = at; s.servers[i].latencyMs = ms }
                    // 檢查時間、延遲不算「畫面要變」：只有在線／離線變了才發布（不然每分鐘重畫一次）；懸停卡讀 latest 拿得到
                    if state.servers[i].online == ok { state = s; setLatest(s); return }
                    publish(s)
                }
            }
        }
    }

    /// 單埠 TCP connect：連上＝在線；2 秒內沒連上或被拒＝離線。只送 SYN 建連線、立刻關，不傳任何資料
    static func probe(host: String, port: Int, done: @escaping @Sendable (Bool) -> Void) {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return done(false) }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 2
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: NWParameters(tls: nil, tcp: tcp))
        let q = DispatchQueue(label: "showork.city.probe")
        final class Once: @unchecked Sendable { var fired = false }
        let once = Once()
        // 都在同一條 queue 上跑（stateUpdateHandler 與逾時），不會同時進來
        let finish: @Sendable (Bool) -> Void = { ok in
            guard !once.fired else { return }
            once.fired = true
            c.cancel()
            done(ok)
        }
        c.stateUpdateHandler = { st in
            switch st {
            case .ready: finish(true)
            case .failed, .waiting: finish(false)
            default: break
            }
        }
        c.start(queue: q)
        q.asyncAfter(deadline: .now() + 2.5) { finish(false) }
    }

    // MARK: 示範值（SHOWORK_CITY_DEMO=1；名字、數字都是假的）

    static func demoState() -> CityState {
        var s = CityState()
        s.demo = true
        let g: Int64 = 1_000_000_000
        s.disks = [CityDisk(name: "Data", isInternal: true, total: 245 * g, available: 13 * g, availablePlain: 11 * g, format: "APFS", mountPath: "/"),
                   CityDisk(name: "DEMO-SD", isInternal: false, total: 128 * g, available: 35 * g, availablePlain: 35 * g, format: "APFS", mountPath: "/Volumes/DEMO-SD"),
                   CityDisk(name: "DEMO-USB", isInternal: false, total: 64 * g, available: 3 * g, availablePlain: 3 * g, format: "MS-DOS (FAT32)", mountPath: "/Volumes/DEMO-USB"),
                   CityDisk(name: "舊隨身碟", isInternal: false, mounted: false, lastSeen: demoShipAt.addingTimeInterval(-2 * 86400))]
        s.clouds = [CityCloud(name: "iCloud Drive", isICloud: true,
                              sync: CloudSync(remaining: 92 * g, driveState: "idle", lastSync: demoShipAt.addingTimeInterval(-300), caughtUp: true,
                                              pending: 0, blocked: 0, desktopDocs: true), checkedAt: demoShipAt),
                    CityCloud(name: "Google Drive", checkedAt: demoShipAt)]
        s.servers = [CityServer(alias: "demo-server", online: true, checkedAt: demoShipAt, lastOnline: demoShipAt, latencyMs: 12, hostName: "demo-server.local", port: 22),
                     CityServer(alias: "demo-nas", online: false, checkedAt: demoShipAt, lastOnline: demoShipAt.addingTimeInterval(-3 * 3600), latencyMs: 4, hostName: "192.0.2.10", port: 22)]
        s.recent = [CityShip(repo: "demo-app", at: demoShipAt.addingTimeInterval(-120)), CityShip(repo: "demo-site", at: demoShipAt.addingTimeInterval(-5400))]
        s.firewall = CityFirewall(enabled: ProcessInfo.processInfo.environment["SHOWORK_CITY_DEMO"] == "calm", ports: [
            ListenPort(port: 4242, process: "demo-local", external: false), ListenPort(port: 5037, process: "demo-adb", external: false),
            ListenPort(port: 6463, process: "demo-chat", external: false),
            ListenPort(port: 5000, process: "demo-airplay", external: true), ListenPort(port: 7000, process: "demo-airplay", external: true),
            ListenPort(port: 8766, process: "demo-screen", external: true),
            ListenPort(port: 9888, process: "demo-audio", external: true, knownOpen: "audio-bridge")], checkedAt: demoShipAt)
        s.power = CityPower(temp: 92, cpuAvg: 81, level: "hot")
        s.grid = fakeGrid(now: demoShipAt) ?? CityRules.grid(RateLimits(fiveHour: .init(used: 72, resetsAt: demoShipAt.addingTimeInterval(2 * 3600)),
                                                                        sevenDay: .init(used: 40, resetsAt: demoShipAt.addingTimeInterval(4 * 86400))), now: demoShipAt)
        s.repos = 12
        if let r = ProcessInfo.processInfo.environment["SHOWORK_CITY_SHIP"] { s.ships = [CityShip(repo: r, at: demoShipAt)] }
        if ProcessInfo.processInfo.environment["SHOWORK_CITY_DEMO"] == "calm" {
            s.disks[2].available = 40 * g; s.servers[1].online = true; s.firewall.ports.removeLast(); s.power = CityPower(temp: 68, cpuAvg: 30, level: "ok")
            s.disks[0].available = 60 * g
        }
        return s
    }
}
