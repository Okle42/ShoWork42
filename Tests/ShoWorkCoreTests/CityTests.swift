import Foundation
import Testing
@testable import ShoWorkCore

// 10-21 外部空間城市：解析與規則（資料一律是示範值，不是這台電腦的）

@Suite("City")
struct CityTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("容量→貨櫃：層數＝已用比例×4 進位；≥90% 堆到圍籬外；拿不到容量＝空堆場")
    func containers() {
        #expect(CityRules.containers(used: nil) == (0, 0, 0))
        #expect(CityRules.containers(used: 0) == (0, 0, 0))
        #expect(CityRules.containers(used: 0.001) == (1, 1, 0))           // 有用到就至少 1 個
        #expect(CityRules.containers(used: 0.25) == (12, 1, 0))
        #expect(CityRules.containers(used: 0.26) == (13, 2, 0))
        #expect(CityRules.containers(used: 0.73) == (35, 3, 0))
        #expect(CityRules.containers(used: 0.899).overflow == 0)
        #expect(CityRules.containers(used: 0.9) == (43, 4, 2))
        #expect(CityRules.containers(used: 0.97).overflow == 4)
        #expect(CityRules.containers(used: 1.0) == (48, 4, 6))
    }

    @Test("磁碟：已用比例、警示線 90%、名牌（內建寫剩多少、外接寫 %、拔掉寫已拔除）")
    func disks() {
        let a = CityDisk(name: "Data", isInternal: true, total: 245_000_000_000, available: 13_000_000_000)
        #expect(abs(a.used! - 232.0 / 245) < 1e-9 && a.alert)
        #expect(CityText.disk(a) == "內建碟・剩 13G（95%） ⚠")
        let b = CityDisk(name: "DEMO-SD", isInternal: false, total: 128_000_000_000, available: 34_560_000_000)
        #expect(!b.alert && CityText.disk(b) == "DEMO-SD・73%")
        let c = CityDisk(name: "舊隨身碟", isInternal: false, mounted: false)
        #expect(c.used == nil && !c.alert && CityText.disk(c) == "舊隨身碟・已拔除")
        #expect(CityText.disk(CityDisk(name: "X", isInternal: false, total: 0)) == "X・容量讀不到")
        #expect(CityText.bytes(13_400_000_000) == "13G" && CityText.bytes(2_500_000_000) == "2.5G" && CityText.bytes(2_000_000_000_000) == "2.0T")
    }

    @Test("卷過濾：只要 /Volumes 底下的外接碟；系統卷、時光機、根目錄排除")
    func volumes() {
        #expect(CityParse.includeVolume(path: "/Volumes/DEMO-SD", name: "DEMO-SD", isRoot: false, browsable: true))
        for n in ["Recovery", "Preboot", "VM", "Update", "Macintosh HD"] {
            #expect(!CityParse.includeVolume(path: "/Volumes/\(n)", name: n, isRoot: false, browsable: true))
        }
        #expect(!CityParse.includeVolume(path: "/Volumes/com.apple.TimeMachine.localsnapshots", name: "com.apple.TimeMachine.localsnapshots", isRoot: false, browsable: true))
        #expect(!CityParse.includeVolume(path: "/Volumes/Backups of Demo", name: "Backups of Demo", isRoot: false, browsable: true))
        #expect(!CityParse.includeVolume(path: "/", name: "Macintosh HD", isRoot: true, browsable: true))
        #expect(!CityParse.includeVolume(path: "/Volumes/X", name: "X", isRoot: false, browsable: false))
        #expect(!CityParse.includeVolume(path: "/System/Volumes/Data", name: "Data", isRoot: false, browsable: true))
        #expect(CityParse.rememberDisks(["A", "B"], mounted: ["C", "A"]) == ["A", "B", "C"])
    }

    @Test("socketfilterfw：開／關／擋全部／讀不懂")
    func firewall() {
        #expect(CityParse.firewall("Firewall is disabled. (State = 0)\n") == false)
        #expect(CityParse.firewall("Firewall is enabled. (State = 1)") == true)
        #expect(CityParse.firewall("Firewall is blocking all non-essential incoming connections. (State = 2)") == true)
        #expect(CityParse.firewall("Firewall is enabled.") == true)
        #expect(CityParse.firewall("") == nil)
    }

    @Test("lsof：本機才連得到的是城內的門、* 或區網位址是對外城門、9888 是敞開的紅門；IPv4／IPv6 同埠合併")
    func lsof() {
        let s = """
        COMMAND     PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        demoA      100 demo    7u  IPv4 0x0000000000000001      0t0  TCP *:7000 (LISTEN)
        demoA      100 demo    8u  IPv6 0x0000000000000002      0t0  TCP *:7000 (LISTEN)
        demoB      101 demo    3u  IPv4 0x0000000000000003      0t0  TCP 127.0.0.1:4242 (LISTEN)
        demoB      101 demo    4u  IPv6 0x0000000000000004      0t0  TCP [::1]:4242 (LISTEN)
        demoC      102 demo    4u  IPv6 0x0000000000000005      0t0  TCP [::1]:8791 (LISTEN)
        demoC      103 demo    4u  IPv4 0x0000000000000006      0t0  TCP *:8791 (LISTEN)
        audio\\x20b 104 demo    5u  IPv4 0x0000000000000007      0t0  TCP *:9888 (LISTEN)
        demoD      105 demo    5u  IPv4 0x0000000000000008      0t0  TCP 192.0.2.10:5555 (LISTEN)
        garbage line
        """
        let p = CityParse.listen(s)
        #expect(p.map(\.port) == [4242, 5555, 7000, 8791, 9888])
        #expect(p.first { $0.port == 4242 }?.external == false)
        #expect(p.first { $0.port == 7000 }?.external == true)
        #expect(p.first { $0.port == 8791 }?.external == true)        // 一個 loopback、一個 * ⇒ 對外
        #expect(p.first { $0.port == 5555 }?.external == true)
        #expect(p.first { $0.port == 9888 }?.openRed == true && p.first { $0.port == 9888 }?.process == "audio b")
        var f = CityFirewall(enabled: false, ports: p, checkedAt: now)
        #expect(f.gates.count == 4 && f.doors.count == 1 && f.openRed.map(\.port) == [9888])
        #expect(f.summary.contains("防火牆關閉") && f.summary.contains("9888（audio-bridge）"))
        #expect(CityText.wall(f) == "城牆・防火牆關閉 ⚠")
        f.enabled = true
        #expect(CityText.wall(f) == "城牆・防火牆開啟")
        #expect(CityText.wall(CityFirewall()) == "城牆・還沒檢查")
    }

    @Test("ssh config：Host 別名、HostName／Port、跳過萬用字元與重複、Match 區塊不算")
    func ssh() {
        let s = """
        # 示範
        Host demo-server demo-alias
            HostName demo.example.invalid
            Port 2222
        Host *
            ServerAliveInterval 30
        Host=demo-nas
          HostName=nas.example.invalid
        Host *.example.invalid !bad
        Match host demo-nas
            Port 9999
        Host demo-server
            Port 1
        """
        let h = CityParse.sshHosts(s)
        #expect(h.map(\.alias) == ["demo-server", "demo-alias", "demo-nas"])
        #expect(h[0].hostName == "demo.example.invalid" && h[0].port == 2222 && h[1].port == 2222)
        #expect(h[2].hostName == "nas.example.invalid" && h[2].port == 22)
    }

    @Test("cool42：溫度、等級、過期；煙量；2°C 內不重畫")
    func power() {
        let j = #"{"controlTemp":74.8,"cpuAvg":52.0,"level":"ok","time":"2027-01-15T08:00:00Z"}"#.data(using: .utf8)
        let at = ISO8601DateFormatter().date(from: "2027-01-15T08:00:30Z")!
        let p = CityParse.cool42(j, now: at)
        #expect(p.temp == 74.8 && p.cpuAvg == 52 && p.level == "ok" && !p.stale && !p.alert && p.known)
        #expect(CityParse.cool42(j, now: at.addingTimeInterval(600)).stale)
        #expect(CityParse.cool42(nil, now: at) == CityPower())
        #expect(CityText.power(p) == "冷卻水塔・約 70°C" && CityText.power(CityPower()) == "冷卻水塔・cool42 狀態未知")
        let hot = CityPower(temp: 92, level: "hot")
        #expect(hot.alert && CityText.power(hot) == "冷卻水塔・約 90°C hot ⚠")
        #expect(CityRules.smoke(CityPower(temp: 44, level: "ok")) == 0 && CityRules.smoke(CityPower(temp: 52, level: "ok")) == 1 && CityRules.smoke(p) == 3 && CityRules.smoke(hot) == 5)
        #expect(!CityRules.powerChanged(p, CityPower(temp: 75.9, cpuAvg: 60, level: "ok")))
        #expect(!CityRules.powerChanged(p, CityPower(temp: 77, cpuAvg: 52, level: "ok")))     // 換格但只差 2.2°C
        #expect(CityRules.powerChanged(p, CityPower(temp: 81, cpuAvg: 52, level: "ok")))      // 換到 80 那格、差 6°C 以上
        #expect(!CityRules.powerChanged(p, CityPower(temp: 69.5, cpuAvg: 52, level: "ok")))   // 同一格
        #expect(!CityRules.powerChanged(CityPower(temp: 74.9, level: "ok"), CityPower(temp: 75.1, level: "ok")))   // 卡在分界不跳
        #expect(CityRules.powerChanged(p, CityPower(temp: 74.8, cpuAvg: 52, level: "warm")))
    }

    @Test("雲端顯示名不帶帳號；港口：第一次只當基準、變新才出港")
    func cloudAndPort() {
        #expect(CityParse.cloudName("GoogleDrive-demo@example.invalid") == "Google Drive")
        #expect(CityParse.cloudName("OneDrive-Personal") == "OneDrive")
        #expect(CityParse.cloudName("SynologyDrive-demo") == "Synology Drive")
        let t = now
        #expect(CityParse.departures(old: [:], new: ["A": t]).isEmpty)
        #expect(CityParse.departures(old: ["A": t, "B": t], new: ["A": t.addingTimeInterval(5), "B": t, "C": t]) == ["A"])
    }

    @Test("設備警示：≥90% 碟、離線伺服器、防火牆關、敞開紅門、hot；正常的不算")
    func alerts() {
        var s = CityState()
        s.disks = [CityDisk(name: "Data", isInternal: true, total: 100, available: 50),
                   CityDisk(name: "DEMO-SD", isInternal: false, total: 100, available: 5),
                   CityDisk(name: "舊隨身碟", isInternal: false, mounted: false)]
        s.servers = [CityServer(alias: "demo-server", online: true), CityServer(alias: "demo-nas", online: false), CityServer(alias: "demo-new")]
        s.firewall = CityFirewall(enabled: false, ports: [ListenPort(port: 9888, process: "x", external: true, knownOpen: "audio-bridge"),
                                                          ListenPort(port: 9888, process: "x", external: false, knownOpen: "audio-bridge")], checkedAt: now)
        s.power = CityPower(temp: 95, level: "critical")
        #expect(s.alerts.map(\.id) == ["city:disk:DEMO-SD", "city:server:demo-nas", "city:wall", "city:gate:9888", "city:cooler"])
        s.firewall.enabled = nil; s.power.stale = true
        #expect(s.alerts.count == 3)
        #expect(CityText.server(CityServer(alias: "demo-new")) == "demo-new・檢查中" && CityText.server(s.servers[1]) == "demo-nas・離線 ⚠")
        #expect(LabelKind.cityAlert.mustShow && !LabelKind.city.mustShow && LabelKind.cityAlert < .guardian)
    }

    // MARK: 10-21 第二輪：隨身碟容量、iCloud、穿插檢查

    @Test("外接碟可用空間：重要用途可用回 0（FAT32）就改用一般可用")
    func fatAvailable() {
        #expect(CityParse.available(important: 0, plain: 4_018_122_752) == 4_018_122_752)
        #expect(CityParse.available(important: nil, plain: 5) == 5)
        #expect(CityParse.available(important: 37, plain: 35) == 37)
        #expect(CityParse.available(important: nil, plain: nil) == 0)
        let d = CityDisk(name: "DEMO-FAT", isInternal: false, total: 4_019_306_496, available: CityParse.available(important: 0, plain: 4_018_122_752))
        #expect(!d.alert && CityRules.containers(used: d.used).overflow == 0)
        #expect(CityText.disk(d) == "DEMO-FAT・<1%")
    }

    // 假資料：容器名稱照 brctl 管線輸出的遮蔽格式，但都是編的
    static let brAll = """
    5 containers matching '*'
    <d{3}o.a{3}e.X{4}s[7] \u{1B}[0;1;30mbackground\u{1B}[0m {client:\u{1B}[0;1mblocked-app-uninstalled\u{1B}[0m server:full-sync sync:idle last-sync:2026-05-01 21:18:12.924, consistent zoneActiveState:{(null)} appuninstalled:2026-09-19 16:28:29 +0000}>
    \u{1B}[0;1;34m>>> SYNC DISABLED (app not installed)\u{1B}[0m
    <d{3}o.b{3}e.Y{4}s[8] \u{1B}[0;1;30mbackground\u{1B}[0m {client:\u{1B}[31mneeds-sync\u{1B}[39m|\u{1B}[0;1mblocked-app-uninstalled\u{1B}[0m server:idle sync:idle last-sync:never zoneActiveState:{(null)}}>
    \u{1B}[0;1;34m>>> SYNC DISABLED (app not installed)\u{1B}[0m
    <c{1}m.a{3}e.C{7}s[1] \u{1B}[0;1;32mforeground\u{1B}[0m {client:idle server:full-sync sync:has-synced-down last-sync:2026-10-21 04:16:03.061, requestID:2284, caught-up, token:x zoneActiveState:{rid:2285}}>
    <d{3}o.c{3}e.Z{4}s[9] \u{1B}[0;1;30mbackground\u{1B}[0m {client:\u{1B}[31mneeds-sync\u{1B}[39m server:idle sync:idle last-sync:2026-10-20 10:00:00.000, consistent}>
    <d{3}o.d{3}e.W{4}s[10] \u{1B}[0;1;30mbackground\u{1B}[0m {client:\u{1B}[0;1mblocked-quota-full\u{1B}[0m server:idle sync:idle last-sync:2026-10-20 10:00:00.000, consistent}>
    """
    static let brMain = """
    1 containers matching 'com.apple.CloudDocs'
    <c{1}m.a{3}e.C{7}s[1] \u{1B}[0;1;32mforeground\u{1B}[0m {client:idle server:full-sync sync:has-synced-down last-sync:2026-10-21 04:16:03.061, requestID:2284, caught-up, token:x zoneActiveState:{rid:2285}}>

    Desktop & Documents: current=YES lastEnabled=(never) lastDisabled=(never)
    """

    @Test("brctl：剩餘額度、容器狀態（App 已刪除的不算錯）、桌面與文件")
    func brctl() {
        #expect(CityParse.brctlQuota("92346786485 bytes of quota remaining in personal account\n") == 92_346_786_485)
        #expect(CityParse.brctlQuota("error: not signed in") == nil)
        let tz = TimeZone(identifier: "Asia/Taipei")!
        let (cs, dd) = CityParse.brctlStatus(Self.brAll, timeZone: tz)
        #expect(cs.count == 5 && dd == nil)
        #expect(cs[0].disabled && cs[1].disabled && !cs[2].disabled && !cs[3].disabled)
        #expect(cs[1].needsSync && !cs[1].blocked && cs[1].lastSync == nil)
        #expect(cs[2].name == "c{1}m.a{3}e.C{7}s" && cs[2].client == ["idle"] && cs[2].caughtUp)
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 21; c.hour = 4; c.minute = 16; c.second = 3
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        #expect(abs(cs[2].lastSync!.timeIntervalSince(cal.date(from: c)!) - 0.061) < 0.01)
        #expect(cs[4].blocked)
        #expect(CityParse.brctlStatus(Self.brMain).desktopDocs == true)
    }

    @Test("iCloud 狀態：名牌寫剩多少；卡住、被擋、快滿才警示；讀不到只寫已連線")
    func icloud() {
        let s = CityParse.cloudSync(quota: "92346786485 bytes of quota remaining in personal account", main: Self.brMain, all: Self.brAll)!
        #expect(s.remaining == 92_346_786_485 && s.driveState == "idle" && s.caughtUp && s.desktopDocs == true)
        #expect(s.pending == 1 && s.blocked == 1)        // 已刪除 App 的兩個不算；主容器本身不算
        let now = s.lastSync!.addingTimeInterval(600)
        var c = CityCloud(name: "iCloud Drive", isICloud: true, sync: s, checkedAt: now)
        #expect(c.alert && CityText.cloud(c) == "iCloud・1 項被擋 ⚠")
        c.sync!.blocked = 0
        #expect(!c.alert && CityText.cloud(c) == "iCloud・剩 92G")
        c.sync!.remaining = 3_000_000_000
        #expect(c.alert && CityText.cloud(c) == "iCloud・剩 3.0G ⚠")
        c.sync!.remaining = 92_000_000_000; c.sync!.driveState = "needs-sync"
        #expect(!c.alert)                                   // 剛存檔待同步：10 分鐘內不算卡住
        c.checkedAt = s.lastSync!.addingTimeInterval(7200)
        #expect(c.alert && CityText.cloud(c) == "iCloud・同步卡住 ⚠")
        #expect(CityParse.cloudSync(quota: "nope", main: nil, all: nil) == nil)
        #expect(CityText.cloud(CityCloud(name: "iCloud Drive", isICloud: true)) == "iCloud・已連線")
        #expect(CityText.cloud(CityCloud(name: "Google Drive")) == "Google Drive・已連線")
        var st = CityState(); st.clouds = [c]
        #expect(st.alerts.map(\.id) == ["city:cloud:iCloud Drive"])
    }

    @Test("方塊穿插：貼著不算、轉了角度插進去算")
    func boxes() {
        let a = CityBox(center: SIMD3(0, 0.5, 0), size: SIMD3(1.5, 1, 0.9))
        #expect(CityBox.penetration(a, CityBox(center: SIMD3(1.5, 0.5, 0), size: SIMD3(1.5, 1, 0.9))) <= 0)   // 並排貼著
        #expect(CityBox.penetration(a, CityBox(center: SIMD3(0, 1.5, 0), size: SIMD3(1.5, 1, 0.9))) <= 0)     // 疊上去
        #expect(CityBox.penetration(a, CityBox(center: SIMD3(1.0, 0.5, 0.3), size: SIMD3(1.5, 1, 0.9))) > 0.4)
        // 歪 0.35 弧度、中心離 1.4：轉過的角會插進去
        let r = CityBox(center: SIMD3(1.4, 0.5, 0.3), size: SIMD3(1.5, 1, 0.9), yaw: 0.35)
        #expect(r.rotated && CityBox.penetration(a, r) > 0.05)
        #expect(CityBox.penetration(a, CityBox(center: SIMD3(3, 0.5, 0), size: SIMD3(1.5, 1, 0.9), yaw: 0.35)) <= 0)
        #expect(!CityBox(center: .zero, size: .one, yaw: .pi / 2).rotated)
    }

    // MARK: 10-22 電廠＝AI 額度

    @Test("額度 → 電力階段：80／95／100% 三段、7 天用完也停電、重置過了算新的一輪")
    func gridStages() {
        let t = now
        func g(_ five: Double, _ seven: Double = 10, reset: TimeInterval = 3600) -> CityGrid {
            CityRules.grid(RateLimits(fiveHour: .init(used: five, resetsAt: t + reset), sevenDay: .init(used: seven, resetsAt: t + 86400)), now: t)
        }
        #expect(g(79).stage == .normal && g(80).stage == .dim && g(94.9).stage == .dim && g(95).stage == .flicker && g(100).stage == .blackout)
        #expect(g(20, 100).stage == .blackout)
        #expect(g(100, reset: -60).stage == .normal && g(100, reset: -60).fiveLeft == 100)
        #expect(CityRules.grid(nil, now: t) == CityGrid() && !CityGrid().known)
        #expect(!g(94).alert && g(96).alert && g(100).lightScale == 0 && g(85).lightScale == 0.6)
    }

    @Test("跨門檻才換：已用 % 每 1%（跟右上角同步）、階段、重置分鐘")
    func gridChanged() {
        let t = now
        func g(_ five: Double, reset: TimeInterval = 3600) -> CityGrid {
            CityRules.grid(RateLimits(fiveHour: .init(used: five, resetsAt: t + reset), sevenDay: .init(used: 40, resetsAt: t + 86400)), now: t)
        }
        #expect(!CityRules.gridChanged(g(61.2), g(61.4)))      // 右上角都顯示 61%
        #expect(CityRules.gridChanged(g(61), g(62)))           // 右上角 61 → 62，名牌也跟著換
        #expect(CityRules.gridChanged(g(79.5), g(80)))         // 進節電
        #expect(!CityRules.gridChanged(g(50, reset: 3600), g(50, reset: 3620)))
        #expect(CityRules.gridChanged(g(50, reset: 3600), g(50, reset: 3700)))
    }

    @Test("電廠、油槽名牌；停電寫幾點復電；警示列")
    func gridText() {
        let tz = TimeZone(identifier: "Asia/Taipei")!
        let t = Date(timeIntervalSince1970: 1_792_630_000)        // 10-22 08:46 台北
        let r = RateLimits(fiveHour: .init(used: 67, resetsAt: Date(timeIntervalSince1970: 1_792_632_000)),
                           sevenDay: .init(used: 67, resetsAt: Date(timeIntervalSince1970: 1_792_656_000)))
        let a = CityRules.grid(r, now: t)
        #expect(CityText.grid(a, now: t, tz: tz) == "電廠・5 小時已用 67%（09:20 重置）")
        #expect(CityText.fuel(a) == "油槽・7 天已用 67%（7 小時 10 分後重置）")
        #expect(CityText.countdown(2 * 1440 + 5 * 60 + 33) == "2 天 5 小時" && CityText.countdown(42) == "42 分" && CityText.countdown(nil) == nil)
        var b = r; b.fiveHour?.used = 100
        let out = CityRules.grid(b, now: t)
        #expect(CityText.grid(out, now: t, tz: tz) == "停電・額度用完，09:20 復電 ⚠")
        var s = CityState(); s.grid = out
        #expect(s.alerts.map(\.id) == ["city:power"] && s.alerts[0].text == "停電：AI 額度用完")
        #expect(CityText.grid(CityGrid(), now: t) == "電廠・額度讀不到")
    }
}
