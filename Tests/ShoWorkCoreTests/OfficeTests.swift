import Foundation
import simd
import Testing
@testable import ShoWorkCore

// 3D 辦公室資料層（10-20）：常駐部門名冊、前台・保全（wifiwatch）、格局／燈光設定

@Suite("Office")
struct OfficeTests {
    let now = Date()
    let day: TimeInterval = 86400

    func reflog(_ lines: [(TimeInterval, String)]) -> String {
        lines.map { "0000000 1111111 Kang Lin <k@example.com> \(Int($0.0)) +0800\t\($0.1)" }.joined(separator: "\n") + "\n"
    }

    /// 在暫存資料夾做一個假的 ~/github-repos
    func fixture() throws -> String {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("office-\(UUID().uuidString)").path
        func repo(_ name: String, _ log: String?) throws {
            try fm.createDirectory(atPath: "\(root)/\(name)/.git/logs", withIntermediateDirectories: true)
            if let log { try log.write(toFile: "\(root)/\(name)/.git/logs/HEAD", atomically: true, encoding: .utf8) }
        }
        try repo("ShoWork42", reflog([(now.timeIntervalSince1970 - 2 * day, "commit: 戰情中心")]))
        try repo("ProjectB", reflog([(now.timeIntervalSince1970 - 10 * day, "commit (initial): 初始化")]))
        try repo("ProjectA", reflog([(now.timeIntervalSince1970 - 40 * day, "commit: 舊"), (now.timeIntervalSince1970 - 1 * day, "pull --ff-only: Fast-forward")]))
        try repo("agreement", reflog([(now.timeIntervalSince1970 - 28 * day, "commit (merge): 合併")]))
        // 只有 checkout／reset 是新的，commit 在 30 天外 ⇒ 不算
        try repo("old-checkout", reflog([(now.timeIntervalSince1970 - 45 * day, "commit: 很久以前"),
                                         (now.timeIntervalSince1970 - 1 * day, "checkout: moving from main to dev"),
                                         (now.timeIntervalSince1970 - 1 * day, "reset: moving to origin/main")]))
        try repo("gadget-old", reflog([(now.timeIntervalSince1970 - 61 * day, "commit: 舊")]))
        // 沒有 reflog、但分支檔是新的 ⇒ 看 refs/heads 的 mtime
        try repo("no-reflog", nil)
        try fm.createDirectory(atPath: "\(root)/no-reflog/.git/refs/heads", withIntermediateDirectories: true)
        try "abc\n".write(toFile: "\(root)/no-reflog/.git/refs/heads/main", atomically: true, encoding: .utf8)
        // 從來沒 commit（homebrew-tap 那種）
        try fm.createDirectory(atPath: "\(root)/empty-repo/.git/refs/heads", withIntermediateDirectories: true)
        // worktree：.git 是檔案
        try fm.createDirectory(atPath: "\(root)/ProjectA-w1", withIntermediateDirectories: true)
        try "gitdir: \(root)/ProjectA/.git/worktrees/ProjectA-w1\n".write(toFile: "\(root)/ProjectA-w1/.git", atomically: true, encoding: .utf8)
        // 不是 repo、符號連結（冷資料在 SD 卡）
        try fm.createDirectory(atPath: "\(root)/_本機資料", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: "\(root)/linked", withDestinationPath: "\(root)/ShoWork42")
        return root
    }

    @Test("reflog：取最後一筆 commit／merge／pull，跳過 checkout／reset；名字有空白也讀得到")
    func reflogParse() {
        let d = Data(reflog([(100, "commit: a"), (200, "pull --rebase (finish): returning to refs/heads/main"),
                             (300, "checkout: moving from a to b"), (400, "reset: moving to HEAD~1")]).utf8)
        #expect(ResidentProjects.reflogLastCommit(d) == Date(timeIntervalSince1970: 200))
        #expect(ResidentProjects.reflogLastCommit(Data(reflog([(5, "checkout: x"), (6, "clone: from y")]).utf8)) == nil)
        #expect(ResidentProjects.reflogLastCommit(Data(reflog([(7, "merge origin/main: Fast-forward")]).utf8)) == Date(timeIntervalSince1970: 7))
        #expect(ResidentProjects.reflogLastCommit(Data()) == nil)
    }

    @Test("常駐名冊：30 天內有 commit 的第一層 repo，依名稱排序；worktree、符號連結、沒 commit 的不算")
    func residents() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let r = ResidentProjects.scan(root: root, now: now.addingTimeInterval(day))   // refs 檔 mtime 是現在，往後看一天也在 30 天內
        #expect(r.map(\.name) == ["agreement", "no-reflog", "ProjectA", "ProjectB", "ShoWork42"])
        #expect(r.first { $0.name == "ProjectA" }?.lastCommit.timeIntervalSince1970 == Double(Int(now.timeIntervalSince1970 - day)))   // pull 也算
    }

    @Test("名稱對得上 BoardCard.project：repo 裡任何子資料夾都算那個部門，家目錄是臨時部門")
    func namesMatchProject() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fm = FileManager.default
        let isRepo: (String) -> Bool = { fm.fileExists(atPath: $0 + "/.git") }
        let names = ResidentProjects.scan(root: root, now: now).map(\.name)
        for n in names {
            #expect(Board.projectName(cwd: "\(root)/\(n)/Sources/深/一層", home: "/Users/x", isRepo: isRepo) == n)
        }
        // worktree 的 project 是自己的資料夾名，不在常駐名冊 ⇒ 臨時部門
        let wt = Board.projectName(cwd: "\(root)/ProjectA-w1/src", home: "/Users/x", isRepo: isRepo)
        #expect(wt == "ProjectA-w1" && !names.contains(wt))
        let home = Board.projectName(cwd: "/Users/x", home: "/Users/x", isRepo: isRepo)
        #expect(home == "（家目錄）")
        func card(_ p: String) -> BoardCard { BoardCard(id: p, column: .active, reason: "", project: p, title: "t", lastActivity: nil, pid: 1, sessionId: p) }
        let deps = OfficeDepartments.build(residents: names, cards: [card(home), card(wt), card("ShoWork42")])
        #expect(deps.map(\.name) == names + ["（家目錄）", "ProjectA-w1"])
        #expect(deps.filter(\.isActive).map(\.name) == ["ShoWork42", "（家目錄）", "ProjectA-w1"])
        #expect(deps.filter { !$0.isResident }.allSatisfy { $0.isActive })
    }

    @Test("部門位置穩定：誰在忙、卡片順序都不影響常駐部門的位置；大小寫不同算同一個；排隊訊息也算有人")
    func stableOrder() {
        func card(_ id: String, _ p: String, _ col: BoardColumn) -> BoardCard {
            BoardCard(id: id, column: col, reason: "", project: p, title: "t", lastActivity: nil, pid: 1, sessionId: id)
        }
        let residents = ["MoneyBot42", "ProjectD", "ShoWork42"]
        let a = OfficeDepartments.build(residents: residents, cards: [card("1", "ShoWork42", .active), card("2", "zeta", .done), card("3", "Alpha", .done)])
        let b = OfficeDepartments.build(residents: residents, cards: [card("3", "Alpha", .stuck), card("1", "showork42", .review), card("2", "zeta", .active)])
        #expect(a.map(\.name) == ["MoneyBot42", "ProjectD", "ShoWork42", "Alpha", "zeta"])
        #expect(a == b)
        let q = OfficeDepartments.build(residents: residents, cards: [card("x#q0", "ProjectD", .todo)])
        #expect(q.map(\.isActive) == [false, true, false])
        #expect(OfficeDepartments.build(residents: residents, cards: []).allSatisfy { $0.isResident && !$0.isActive })
    }

    // MARK: 保全

    let tz = TimeZone(identifier: "Asia/Taipei")!
    func local(_ s: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz; f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: s)!
    }
    let devices = """
    {
      "02:00:00:00:10:01": {"first_seen": "2026-09-22T22:48:01", "label": "示範路由器", "vendor": "示範廠商A", "last_seen": "2026-09-23T12:04:16", "last_ip": "192.0.2.1"},
      "02:00:00:00:10:02": {"first_seen": "2026-09-22T22:48:01", "label": "示範掃地機", "vendor": "示範廠商B", "last_seen": "2026-09-22T23:19:02", "last_ip": "192.0.2.102"},
      "02:00:00:00:10:03": {"first_seen": "2026-09-22T22:48:01", "label": "★不在你清單上的裝置", "vendor": "示範廠商C", "last_seen": "2026-09-23T12:04:16", "last_ip": "192.0.2.202"},
      "02:00:00:00:10:04": {"first_seen": "2026-09-22T22:49:03", "label": "", "vendor": "示範廠商D", "last_seen": "2026-09-23T12:04:10", "last_ip": "192.0.2.101"},
      "aa:bb:cc:dd:ee:01": {"first_seen": "2026-09-22T22:48:01", "label": "", "vendor": "未知廠商", "last_seen": "2026-09-22T23:00:00", "last_ip": "192.0.2.150"}
    }
    """
    let log = """
    2026-09-22 22:48:01  BASELINE  建立名冊，收錄 13 台裝置
    2026-09-22 22:49:03  NEW  192.0.2.101  02:00:00:00:10:04  示範廠商D
    2026-09-22 22:58:33  NEW  (僅 IPv6)  9e:39:04:94:c6:82  （隨機 MAC・隱私位址）
    # 註記（人工補上）：上面那筆是測試用假警報，名冊已還原
    """

    @Test("wifiwatch：上次掃描＝最新 last_seen、在線＝跟它差 2 分鐘內；NEW＋沒命名＝新裝置；被 forget 的 NEW 不算")
    func guardParse() {
        let s = WifiWatch.parse(devices: Data(devices.utf8), log: Data(log.utf8), now: local("2026-09-23T13:00:00"), timeZone: tz)
        #expect(s.hasData && s.knownCount == 5)
        #expect(s.lastScan == local("2026-09-23T12:04:16"))
        #expect(s.onlineCount == 3)                                     // 路由器、Quectel、Epson（差 6 秒）
        #expect(!s.stale)
        #expect(s.flagged.map(\.mac) == ["02:00:00:00:10:04", "02:00:00:00:10:03", "aa:bb:cc:dd:ee:01"])   // 在線的在前
        #expect(s.flagged.map(\.kind) == [.new, .unconfirmed, .unnamed])
        #expect(s.flagged.map(\.online) == [true, true, false])
        #expect(!s.flagged.contains { $0.mac == "9e:39:04:94:c6:82" })
        #expect(s.level == .alert)                                      // 沒命名的 Epson 在線上
        #expect(s.summary.contains("上次在線 3 台／名冊 5 台"))
    }

    @Test("保全等級：都命名＋最近掃過＝正常；超過 24 小時＝注意；只有 ★ 待確認＝注意；沒有名冊＝注意")
    func guardLevels() {
        let ok = """
        {"a": {"label": "路由器", "last_seen": "2026-10-20T10:00:00"}, "b": {"label": "iPhone", "last_seen": "2026-10-20T09:00:00"}}
        """
        let fresh = WifiWatch.parse(devices: Data(ok.utf8), log: nil, now: local("2026-10-20T12:00:00"), timeZone: tz)
        #expect(fresh.level == .normal && fresh.onlineCount == 1 && fresh.flagged.isEmpty)
        let old = WifiWatch.parse(devices: Data(ok.utf8), log: nil, now: local("2026-10-21T10:00:01"), timeZone: tz)
        #expect(old.level == .notice && old.stale && old.summary.hasPrefix("很久沒掃描"))
        let star = """
        {"a": {"label": "★不在你清單上", "last_seen": "2026-10-20T10:00:00"}}
        """
        #expect(WifiWatch.parse(devices: Data(star.utf8), log: nil, now: local("2026-10-20T11:00:00"), timeZone: tz).level == .notice)
        let none = WifiWatch.parse(devices: nil, log: nil, now: now)
        #expect(!none.hasData && none.level == .notice && none.lastScan == nil)
        #expect(WifiWatch.parse(devices: Data("壞掉".utf8), log: nil, now: now).hasData == false)
        #expect(GuardLevel.normal < .notice && GuardLevel.notice < .alert)
    }

    @Test("保全：只有 IPv6 的隨機 MAC（手機隱私位址）在線只算注意；有 IPv4 的沒命名裝置在線才警示（10-20 審查）")
    func guardPrivacyMAC() {
        let v6 = """
        {"02:00:00:00:10:01": {"label": "路由器", "last_ip": "192.0.2.1", "last_seen": "2026-10-20T16:38:09"},
         "f6:f3:9f:84:12:fb": {"label": "", "vendor": "（隨機 MAC・隱私位址）", "last_ip": null, "last_seen": "2026-10-20T16:38:09"}}
        """
        let log6 = "2026-10-20 16:12:27  NEW  (僅 IPv6)  f6:f3:9f:84:12:fb  （隨機 MAC・隱私位址）"
        let s = WifiWatch.parse(devices: Data(v6.utf8), log: Data(log6.utf8), now: local("2026-10-20T17:00:00"), timeZone: tz)
        #expect(s.flagged.count == 1 && s.flagged[0].kind == .new && s.flagged[0].online && s.flagged[0].privacyOnly)
        #expect(s.level == .notice)
        #expect(s.summary.contains("1 台沒命名（1 台只有 IPv6 隨機位址）"))
        // 同一台如果拿到 IPv4 ⇒ 警示
        let v4 = v6.replacingOccurrences(of: "\"last_ip\": null", with: "\"last_ip\": \"192.0.2.77\"")
        #expect(WifiWatch.parse(devices: Data(v4.utf8), log: Data(log6.utf8), now: local("2026-10-20T17:00:00"), timeZone: tz).level == .alert)
        // 不是隨機 MAC（廠商 MAC）就算只有 IPv6 也警示
        let vendorMAC = v6.replacingOccurrences(of: "f6:f3:9f:84:12:fb", with: "f4:f3:9f:84:12:fb")
        #expect(WifiWatch.parse(devices: Data(vendorMAC.utf8), log: nil, now: local("2026-10-20T17:00:00"), timeZone: tz).level == .alert)
        #expect(WifiWatch.isLocallyAdministered("9e:45:8b:0f:65:c1") && !WifiWatch.isLocallyAdministered("f0:04:e1:8b:3f:8a"))
    }

    @Test("立即掃描：背景跑、同時只跑一個、跑完可以再跑；測試用注入的 runner，不碰網路")
    func scannerSingleFlight() {
        let gate = DispatchSemaphore(value: 0)
        let calls = Counter()
        let sc = GuardScanner(script: "/假的/wifiwatch.sh") { script in
            calls.add(script); gate.wait(); return 0
        }
        let finished = DispatchSemaphore(value: 0)
        let started = sc.scan(now: now) { code in calls.add("code=\(code)"); finished.signal() }
        #expect(started)
        #expect(sc.isRunning)
        #expect(!sc.scan(now: now))                       // 第二次被擋
        #expect(sc.lastStarted == now)
        gate.signal()
        finished.wait()
        #expect(!sc.isRunning)
        let again = DispatchSemaphore(value: 0)
        let second = sc.scan { _ in again.signal() }
        #expect(second)
        gate.signal(); again.wait()
        #expect(calls.items.filter { $0 != "code=0" } == ["/假的/wifiwatch.sh", "/假的/wifiwatch.sh"])
        #expect(calls.items.contains("code=0"))
    }

    @Test("定時巡邏：關著不巡；名冊 30 分鐘內更新過、或 30 分鐘內自己開始過、或正在跑都不巡")
    func patrolDue() {
        let t = now
        #expect(!GuardScanner.patrolDue(enabled: false, running: false, lastScan: nil, lastStarted: nil, now: t))
        #expect(GuardScanner.patrolDue(enabled: true, running: false, lastScan: nil, lastStarted: nil, now: t))
        #expect(!GuardScanner.patrolDue(enabled: true, running: true, lastScan: nil, lastStarted: nil, now: t))
        #expect(!GuardScanner.patrolDue(enabled: true, running: false, lastScan: t.addingTimeInterval(-29 * 60), lastStarted: nil, now: t))
        #expect(GuardScanner.patrolDue(enabled: true, running: false, lastScan: t.addingTimeInterval(-31 * 60), lastStarted: nil, now: t))
        // 掃描失敗、名冊時間沒動：上次開始在 30 分鐘內就不重掃
        #expect(!GuardScanner.patrolDue(enabled: true, running: false, lastScan: t.addingTimeInterval(-day), lastStarted: t.addingTimeInterval(-60), now: t))
    }

    // MARK: 格局與燈光

    @Test("燈光：自動＝跟台北真實太陽；白天／夜晚固定＝改版前兩組；下一次重算的時間")
    func lighting() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        // 10-21 台北：日出 05:55、日落 17:22
        #expect(!OfficeLighting.auto.isNight(at: local("2026-10-21T12:00:00"), calendar: cal))
        #expect(!OfficeLighting.auto.isNight(at: local("2026-10-21T17:25:00"), calendar: cal))      // 剛日落還亮
        #expect(OfficeLighting.auto.isNight(at: local("2026-10-21T18:00:00"), calendar: cal))
        #expect(OfficeLighting.auto.isNight(at: local("2026-10-21T22:00:00"), calendar: cal))
        #expect(OfficeLighting.auto.isNight(at: local("2026-10-21T05:20:00"), calendar: cal))
        #expect(!OfficeLighting.auto.isNight(at: local("2026-10-21T06:00:00"), calendar: cal))
        #expect(OfficeLighting.night.isNight(at: local("2026-10-20T12:00:00"), calendar: cal))
        #expect(!OfficeLighting.day.isNight(at: local("2026-10-20T23:00:00"), calendar: cal))
        #expect(OfficeLighting.day.look(at: now) == .day && OfficeLighting.night.look(at: now) == .night)
        // 晨昏每分鐘、白天每 5 分鐘、夜晚睡到天快亮（04:5x）
        let dusk = local("2026-10-21T17:30:00")
        #expect(OfficeLighting.auto.nextChange(after: dusk, calendar: cal) == dusk.addingTimeInterval(60))
        let noon = local("2026-10-21T12:00:00")
        #expect(OfficeLighting.auto.nextChange(after: noon, calendar: cal) == noon.addingTimeInterval(300))
        let late = OfficeLighting.auto.nextChange(after: local("2026-10-21T22:00:00"), calendar: cal)!
        #expect(late > local("2026-10-22T04:45:00") && late < local("2026-10-22T05:15:00"))
        #expect(OfficeLighting.day.nextChange(after: now, calendar: cal) == nil)
        #expect(OfficeLighting.auto.label(at: local("2026-10-21T17:25:00")) == "自動・日落")
        #expect(OfficeLighting.auto.label(at: local("2026-10-21T05:20:00")) == "自動・清晨")
    }

    @Test("太陽：台北冬至、夏至、今天的日出日落（NOAA）跟參考值差 ≤ 3 分鐘")
    func sunTimes() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        // 參考值：中央氣象署天文日曆台北（冬至 06:34／17:10、夏至 05:04／18:47）；與 USNO 演算法互相印證
        for (d, rise, set) in [("2026-12-21", "06:34", "17:10"), ("2026-06-21", "05:04", "18:47"), ("2026-10-21", "05:55", "17:22")] {
            let t = Solar.sunTimes(on: local("\(d)T12:00:00"), calendar: cal)!
            #expect(abs(t.sunrise.timeIntervalSince(local("\(d)T\(rise):00"))) <= 180, "\(d) 日出 \(t.sunrise)")
            #expect(abs(t.sunset.timeIntervalSince(local("\(d)T\(set):00"))) <= 180, "\(d) 日落 \(t.sunset)")
            // 日出那一刻：幾何仰角 −0.833°，加上大氣折射後看到的約 −0.4°；正午在南方
            #expect(Solar.position(at: t.sunrise).elevation > -0.7 && Solar.position(at: t.sunrise).elevation < 0)
            let n = Solar.position(at: t.noon)
            #expect(abs(n.azimuth - 180) < 1 || d == "2026-06-21")       // 夏至台北正午太陽在天頂北邊一點
        }
        // 夏至正午仰角 ≈ 90 − |25.03 − 23.44| ≈ 88.4°；冬至 ≈ 41.5°
        #expect(abs(Solar.position(at: Solar.sunTimes(on: local("2026-06-21T12:00:00"), calendar: cal)!.noon).elevation - 88.4) < 0.5)
        #expect(abs(Solar.position(at: Solar.sunTimes(on: local("2026-12-21T12:00:00"), calendar: cal)!.noon).elevation - 41.5) < 0.5)
        // 東升西落
        let m = Solar.position(at: local("2026-10-21T07:00:00")), e = Solar.position(at: local("2026-10-21T17:00:00"))
        #expect(m.azimuth > 90 && m.azimuth < 130 && m.rising)
        #expect(e.azimuth > 230 && e.azimuth < 270 && !e.rising)
    }

    @Test("天色：仰角連續混合、兩端等於改版前白天／夜晚、不跳變")
    func skyBlend() {
        #expect(SkyLook.at(SunSample(elevation: -30, azimuth: 0, rising: true)) == .night)
        var d = SkyLook.at(SunSample(elevation: 40, azimuth: 180, rising: false)); d.sunDir = nil
        #expect(d == .day)
        for rising in [true, false] {
            var prev = SkyLook.at(SunSample(elevation: -14, azimuth: 90, rising: rising))
            for i in 1...400 {
                let e = -14 + Double(i) * 0.1
                let l = SkyLook.at(SunSample(elevation: e, azimuth: 90, rising: rising))
                // 每 0.1°（約 25 秒）顏色變化 < 2%、強度變化 < 25 lux、暗度／燈 < 0.02：沒有一瞬間的跳變
                #expect(abs(l.dark - prev.dark) < 0.02 && abs(l.lamps - prev.lamps) < 0.02)
                #expect(abs(l.ambientIntensity - prev.ambientIntensity) < 25 && abs(l.keyIntensity - prev.keyIntensity) < 25)
                #expect(simd_reduce_max(abs(l.horizon - prev.horizon)) < 0.02)
                prev = l
            }
            // 燈：黃昏逐漸點亮（不是一瞬間）
            let half = SkyLook.at(SunSample(elevation: -1.5, azimuth: 90, rising: rising)).lamps
            #expect(half > 0.3 && half < 0.7)
        }
    }

    @Test("設定：預設 grid／auto／巡邏關；寫了讀得回來；亂寫的值退回預設")
    func prefs() {
        let name = "showork.test.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        let p = OfficePrefs(store: store)
        #expect(p.layout == .grid && p.lighting == .auto && p.guardPatrol == false)
        p.layout = .ring; p.lighting = .night; p.guardPatrol = true
        #expect(store.string(forKey: "office.layout") == "ring")
        #expect(store.string(forKey: "office.lighting") == "night")
        #expect(store.bool(forKey: "office.guardPatrol"))
        #expect(OfficePrefs(store: store).layout == .ring && OfficePrefs(store: store).isNight(at: now))
        store.set("diagonal", forKey: "office.layout"); store.set("dusk", forKey: "office.lighting")
        #expect(p.layout == .grid && p.lighting == .auto)
    }
}

/// 執行緒安全的小計數器（runner 在背景佇列被叫）
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ s: String) { lock.lock(); list.append(s); lock.unlock() }
    var items: [String] { lock.lock(); defer { lock.unlock() }; return list }
}
