import AppKit
import SceneKit
import ShoWorkCore

let argv = CommandLine.arguments

// Internal: exit 0 if this binary is trusted for Accessibility (used by the permission wait loop)
if argv.count == 2, argv[1] == "--ax-check" { exit(AXIsProcessTrusted() ? 0 : 1) }

// Debug: ShoWorkAgent --arrange-dry   → prints the frames it WOULD apply (moves nothing)
if argv.count == 2, argv[1] == "--arrange-dry" {
    MainActor.assumeIsolated {
        let a = Arranger.shared
        let p = a.plan()
        print("screens", a.screenAreasAX(), "windows", p.count)
        for (t, f) in p { print(t.app, AXQuery.wid(t.el), "now", t.frame, "→", f) }
        exit(0)
    }
}
// Test: ShoWorkAgent --arrange-once [columns|grid]  → arrange current Space once, print "wid x y w h" planned, exit
if argv.count >= 2, argv[1] == "--arrange-once" {
    MainActor.assumeIsolated {
        let a = Arranger.shared
        if argv.count == 3, let s = LayoutPlan.FourStyle(rawValue: argv[2]) { a.fourStyle = s }
        guard Arranger.onlyWIDs != nil else {       // the test entry point never runs without a whitelist
            FileHandle.standardError.write(Data("--arrange-once requires SHOWORK_ONLY_WIDS\n".utf8)); exit(3)
        }
        let p = a.plan()
        guard a.arrange(p) else { exit(4) }
        for (t, f) in p { print(AXQuery.wid(t.el), Int(f.minX), Int(f.minY), Int(f.width), Int(f.height)) }
        exit(0)
    }
}

// Test: ShoWorkAgent --arrange-watch  → arrange (whitelist required), then keep restacking on focus changes
if argv.count >= 2, argv[1] == "--arrange-watch" {
    MainActor.assumeIsolated {
        guard Arranger.onlyWIDs != nil else { FileHandle.standardError.write(Data("--arrange-watch requires SHOWORK_ONLY_WIDS\n".utf8)); exit(3) }
        let a = Arranger.shared
        let p = a.plan()
        guard a.arrange(p) else { exit(4) }
        for (t, f) in p { print(AXQuery.wid(t.el), Int(f.minX), Int(f.minY), Int(f.width), Int(f.height)) }
        fflush(stdout)
        a.watchFocus()
        NotificationCenter.default.addObserver(forName: Notification.Name("sw42.focus"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { a.focusChanged() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { a.focusChanged() }
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.run()
    }
}

// Debug: ShoWorkAgent --resolve /dev/ttysNNN   → "<app> <pid> <wid> <tabTTY>" per placement
if argv.count == 3, argv[1] == "--resolve" {
    MainActor.assumeIsolated {
        let r = Resolver().placements(for: argv[2])
        if r.isEmpty { print("none"); exit(1) }
        for p in r { print(p.app, p.pid, p.wid, p.tabTTY) }
        exit(0)
    }
}

// Test/debug: ShoWorkAgent --board-dump  → 戰情中心看板目前的卡片（JSON），不開視窗
if argv.count == 2, argv[1] == "--board-dump" {
    let s = BoardReader().read()
    let fm = FileManager.default
    let cards = Board.build(sessions: s.sessions, transcripts: s.transcripts, glows: s.glows, teams: s.teams, inbox: s.inbox,
                            reports: s.reports, reviews: s.reviews, decisions: s.decisions, contexts: s.contexts, nicknames: s.nicknames,
                            now: Date(), home: BoardPaths.home, isRepo: { fm.fileExists(atPath: $0 + "/.git") })
    let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601
    FileHandle.standardOutput.write(try! e.encode(cards)); print()
    exit(0)
}

// Test/debug: ShoWorkAgent --office-bench <walk|move|still> [秒] [fps]  → 3D 辦公室渲染量測（不開視窗，SCNRenderer 畫進螢幕外貼圖；10-20 第四版）
if argv.count >= 3, argv[1] == "--office-bench" {
    MainActor.assumeIsolated {
        OfficeBench.run(mode: argv[2], seconds: argv.count > 3 ? Double(argv[3]) ?? 20 : 20,
                        fps: argv.count > 4 ? Double(argv[4]) ?? 10 : (argv[2] == "move" ? 24 : argv[2] == "still" ? 12 : 10))
    }
}

// Test/debug: ShoWorkAgent --office-dump  → 3D 辦公室的資料層（10-20）：常駐／臨時部門、保全狀態、格局燈光設定，不開視窗
if argv.count == 2, argv[1] == "--office-dump" {
    let r = BoardReader()
    let s = r.read()
    let fm = FileManager.default
    let cards = Board.build(sessions: s.sessions, transcripts: s.transcripts, glows: s.glows, teams: s.teams, inbox: s.inbox,
                            reports: s.reports, reviews: s.reviews, decisions: s.decisions, contexts: s.contexts, nicknames: s.nicknames,
                            now: Date(), home: BoardPaths.home, isRepo: { fm.fileExists(atPath: $0 + "/.git") })
    let deps = OfficeDepartments.build(residents: s.residents.map(\.name), cards: cards)
    let df = ISO8601DateFormatter(); df.timeZone = .current
    print("repos:", BoardPaths.repos)
    print("departments:", deps.count, "（常駐 \(deps.filter(\.isResident).count)、臨時 \(deps.filter { !$0.isResident }.count)、有人 \(deps.filter(\.isActive).count)）")
    let last = Dictionary(uniqueKeysWithValues: s.residents.map { ($0.name, $0.lastCommit) })
    for (i, d) in deps.enumerated() {
        print(String(format: "%2d", i + 1), d.isResident ? "常駐" : "臨時", d.isActive ? "有人" : "暗著", d.name,
              last[d.name].map { "最後 commit " + df.string(from: $0) } ?? "")
    }
    let g = s.guardStatus
    print("guard:", g.level.title, "|", g.summary)
    print("  hasData=\(g.hasData) lastScan=\(g.lastScan.map(df.string) ?? "nil") known=\(g.knownCount) online=\(g.onlineCount) stale=\(g.stale)")
    for d in g.flagged { print("  flagged", d.kind.rawValue, d.online ? "在線" : "離線", d.ip ?? "-", d.mac, d.label ?? "", d.vendor ?? "") }
    let p = OfficePrefs()
    print("prefs: \(OfficePrefs.layoutKey)=\(p.layout.rawValue) \(OfficePrefs.lightingKey)=\(p.lighting.rawValue) \(OfficePrefs.guardPatrolKey)=\(p.guardPatrol) 現在夜晚=\(p.isNight())")
    print("script:", BoardPaths.wifiwatchScript)
    // 科技大樓（10-20 第 2 棒）：樓層表、主題、閒晃。名冊只讀不存（dump 不改你的樓層號）
    var reg = TowerStore.load()
    let hadReg = !reg.numbers.isEmpty
    var usageShown: [String: Double]?
    let (plan, dirty) = TowerPlan.build(departments: deps, cards: cards, registry: &reg,
                                        usage: { let u = TowerStore.usage(departments: deps, cards: cards); usageShown = u; return u },
                                        accents: TowerDecor.shared.picker.all().mapValues(\.accentColor), now: Date())
    print("tower: 名冊 \(TowerPaths.registry.path)（\(hadReg ? "已存在" : "還沒有，這次是第一次排名")；dump 不存檔\(dirty ? "，正式 agent 會存" : "")）")
    if let u = usageShown {
        print("  7 天用量（MB，對話紀錄檔大小）:", u.sorted { $0.value > $1.value }.map { "\($0.key) \(String(format: "%.1f", $0.value))" }.joined(separator: "、"))
    }
    for f in plan.floors.reversed() {
        let y = String(format: "y=%5.1f h=%.1f", f.y, f.height)
        switch f.kind {
        case .roof: print("  RF  ", y, "空中花園・休息區")
        case .lobby: print("  01  ", y, "大廳＋前台保全（\(g.level.title)）")
        case .idle: print("  薄層", y, f.plates.map { "\($0.floorNo.isEmpty ? "" : $0.floorNo + " ")\($0.name)" }.joined(separator: "、"))
        case .project:
            let last = reg.lastSeen[(f.project ?? "").lowercased()].map { " 最後有人 " + df.string(from: $0) } ?? ""
            print("  \(f.floorNo)  ", y, f.project ?? "", f.active ? "有人" : "緩衝中（2 小時內有人）", "桌 \(f.seats)", last)
        }
    }
    let numbered = reg.numbers.sorted { $0.value < $1.value }.map { "\(TowerSpec.label($0.value)) \(reg.names[$0.key] ?? $0.key)" }
    print("  樓層號:", numbered.joined(separator: "、"))
    // 主題：快取（AI／本地）＋這次用真資料算的本地評分（不呼叫 AI）
    let cache = TowerDecor.shared.picker.all()
    for f in plan.projectFloors {
        guard let name = f.project else { continue }
        let mine = cards.filter { $0.project.caseInsensitiveCompare(name) == .orderedSame && !$0.id.contains("#") }
        let inp = TowerDecor.gather(name, cards: mine, readme: true)
        let sig = WorkSignature.make(inp)
        let top = sig.scores.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key.rawValue) \($0.value)" }.joined(separator: "、")
        let c = cache[name.lowercased()]
        print("  theme \(f.floorNo) \(name): 快取=\(c.map { "\($0.theme.rawValue)（\($0.theme.title)）\($0.source) \($0.accentColor) \($0.props) 「\($0.reason)」" } ?? "無")",
              "| 本地評分=\(sig.best.theme.rawValue)（\(top.isEmpty ? "沒命中" : top)）| 線索: 指示 \(inp.prompts.count)、路徑 \(inp.paths.count)、指令 \(inp.commands.count)、README \(inp.readme == nil ? "無" : "有")")
    }
    let l = TowerDecor.shared.picker.ledgerSnapshot.recent(Date())
    print("  decor: AI 裝潢=\(TowerDecor.shared.enabled ? "開" : "關") 24 小時內呼叫 \(l.count) 次、成本 US$\(String(format: "%.4f", l.reduce(0) { $0 + ($1.cost ?? 0) }))")
    let people = TowerStore.people(cards, tower: plan)
    let w = WanderPlanner.plan(people: people, tower: plan, previous: [:], now: Date(), visible: true, mode: .animate)
    for p in people {
        let st = w.states[p.sid]!
        print("  wander \(p.sid.prefix(8)) \(p.floor) \(p.mood.rawValue) 座位 \(p.seat + 1)/\(p.seats) → \(st.spot)\(st.trip.map { String(format: " 行程 %.1f 秒（%d 點）", $0.duration, $0.nodes.count) } ?? "")")
    }
    exit(0)
}

// Test: ShoWorkAgent --decor-pick <專案> [--real] [--save]  → 跟正式版同一條路（ThemePicker＋同一組 claude 旗標）問一次主題，印結果與耗時。
//       沒帶 --real 用假 runner（不呼叫 AI）；沒帶 --save 寫到暫存資料夾（不動你的 board/themes）（10-20）
if argv.count >= 3, argv[1] == "--decor-pick" {
    let name = argv[2], real = argv.contains("--real"), keep = argv.contains("--save")
    let s = BoardReader().read()
    let fm = FileManager.default
    let cards = Board.build(sessions: s.sessions, transcripts: s.transcripts, glows: s.glows, teams: s.teams, inbox: s.inbox,
                            reports: s.reports, reviews: s.reviews, decisions: s.decisions, contexts: s.contexts, nicknames: s.nicknames,
                            now: Date(), home: BoardPaths.home, isRepo: { fm.fileExists(atPath: $0 + "/.git") })
    let mine = cards.filter { $0.project.caseInsensitiveCompare(name) == .orderedSame && !$0.id.contains("#") }
    let dir = keep ? BoardPaths.dir : fm.temporaryDirectory.appendingPathComponent("showork-decor-\(UUID().uuidString)")
    let picker = ThemePicker(dir: dir, model: DecorRunner.model, runner: real ? DecorRunner.real : DecorRunner.fake)
    let inp = TowerDecor.gather(name, cards: mine, readme: true)
    let sig = WorkSignature.make(inp)
    print("decor-pick \(name) runner=\(real ? "claude -p " + DecorRunner.args().joined(separator: " ") : "假") dir=\(dir.path)")
    print("  卡片 \(mine.count) 張；本地評分 \(sig.best.theme.rawValue)；提示詞 \(DecorPrompt.make(inp, signature: sig, current: nil).count) 字")
    let sem = DispatchSemaphore(value: 0)
    let t0 = Date()
    let ok = picker.consider(name, turnEnded: true, enabled: true, force: true, input: { inp },
                             changed: { v in print("  寫入 \(v.source): \(v.theme.rawValue)（\(v.theme.title)）\(v.accentColor) \(v.props) 「\(v.reason)」 cost=\(v.costUSD.map { String(format: "%.5f", $0) } ?? "-") 秒=\(v.seconds.map { String($0) } ?? "-")"); fflush(stdout) },
                             finished: { d in print("  結果 \(d)，總耗時 \(String(format: "%.1f", Date().timeIntervalSince(t0))) 秒"); fflush(stdout); sem.signal() })
    if !ok { print("  沒有排工作"); exit(1) }
    sem.wait()
    if let c = picker.ledgerSnapshot.calls.last { print("  紀錄: ok=\(c.ok) cost=\(c.cost.map { String($0) } ?? "-") 秒=\(c.seconds.map { String($0) } ?? "-")") }
    exit(0)
}

// Test: ShoWorkAgent --guard-scan [--real]  → 跟「立即掃描」同一條路（GuardScanner、同時只跑一個），印結束碼。
//       沒設 SHOWORK_WIFIWATCH_SCRIPT（假腳本）又沒帶 --real 就不跑：測試不准真的掃網路（10-20）
if argv.count >= 2, argv[1] == "--guard-scan" {
    guard ProcessInfo.processInfo.environment["SHOWORK_WIFIWATCH_SCRIPT"] != nil || argv.dropFirst(2).contains("--real") else {
        print("拒絕：要真的掃描請加 --real；測試請設 SHOWORK_WIFIWATCH_SCRIPT 指向假腳本"); exit(2)
    }
    let sc = BoardActions.guardScanner
    let sem = DispatchSemaphore(value: 0)
    let first = sc.scan { code in print("scan done code=\(code) script=\(sc.script)"); fflush(stdout); sem.signal() }
    let second = sc.scan()                                  // 同時只跑一個：第二次應該被擋
    print("first=\(first) second=\(second) running=\(sc.isRunning)")
    sem.wait()
    print("running after=\(sc.isRunning)")
    exit(0)
}

// Test: ShoWorkAgent --label-sheet <背景.png> <輸出.png>  → 把各狀態的玻璃名牌（假名）疊在背景圖上，驗亮底／暗底的可讀性
//       （螢幕外視窗的截圖拍不到標籤圖層，10-23）
if argv.count == 4, argv[1] == "--label-sheet" {
    MainActor.assumeIsolated { OfficeLabels.labelSheet(bg: argv[2], out: argv[3]) }
    exit(0)
}

// Test: ShoWorkAgent --board-window  → 只開戰情中心視窗（不開 socket、不發光、不需要輔助使用權限）
if argv.count == 2, argv[1] == "--board-window" {
    MainActor.assumeIsolated {
        // 10-21 Bella 實證：.accessory 從 shell 啟動時 run() 仍會被系統啟用、搶走 Kang 的前景（語音輸入被打斷）⇒ 全程 .prohibited，不准中途切回
        NSApplication.shared.setActivationPolicy(.prohibited)
        if let a = ProcessInfo.processInfo.environment["SHOWORK_APPEARANCE"] {      // 截圖驗深淺色用
            NSApplication.shared.appearance = NSAppearance(named: a == "dark" ? .darkAqua : .aqua)
        }
        BoardWindow.testMode = true      // 10-20 Kang：測試視窗不准開到他的螢幕上（開在螢幕外、不搶焦點）
        EditMenu.install()
        if ProcessInfo.processInfo.environment["SHOWORK_TEST_BOARDFRAME"] != nil {   // 終端機排列找得到看板嗎（改 .app 後 owner 名稱會變）
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { print("board frame:", Arranger.boardFrame().map { "\($0)" } ?? "nil"); fflush(stdout) }
        }
        if ProcessInfo.processInfo.environment["SHOWORK_TEST_MENU"] != nil {      // 印出編輯選單（看系統有沒有補「開始聽寫」）
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { print("edit menu:", EditMenu.dump().joined(separator: " | ")); fflush(stdout) }
        }
        BoardWindow.shared.show()
        // SHOWORK_TEST_REOPEN=1（10-24 C）：4 秒後先打開互動板、選大廳、記一個鏡頭，再關窗（內容拆掉）、1 秒後重開；截圖要看到原樣
        if ProcessInfo.processInfo.environment["SHOWORK_TEST_REOPEN"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                OfficeMemory.boardOpen = true; OfficeMemory.selectedFloor = "lobby"
                OfficeMemory.camera = (SCNMatrix4MakeTranslation(18, 6, 14), SCNVector3(2, 1, -1))
                BoardWindow.shared.closeForTest()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    print("reopen: 關窗後內容 \(BoardWindow.shared.hasContent ? "還在" : "已拆")"); fflush(stdout)
                    BoardWindow.shared.show()
                }
            }
        }
        // SHOWORK_TEST_DROP=<路徑>（10-26）：10 秒後（等卡片讀完）對對話輸入框跑拖檔那段（插路徑＋拉焦點），再用鍵盤事件打「接著打」，印出框裡的字
        if let path = ProcessInfo.processInfo.environment["SHOWORK_TEST_DROP"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                func all(_ v: NSView) -> [DropTextView] { [v as? DropTextView].compactMap { $0 } + v.subviews.flatMap(all) }
                guard let w = NSApp.windows.first(where: { $0.title == "AI工作戰情中心" }), let root = w.contentView,
                      let tv = all(root).max(by: { $0.convert($0.bounds, to: nil).minY > $1.convert($1.bounds, to: nil).minY })   // 最下面那個＝對話窗格
                else { print("drop: 找不到輸入框"); fflush(stdout); return }
                tv.string = "看這個"
                tv.insertPaths([path], at: NSRange(location: (tv.string as NSString).length, length: 0))
                tv.focus()
                (w.firstResponder as? NSTextView)?.insertText("接著打", replacementRange: NSRange(location: NSNotFound, length: 0))
                print("drop: 焦點在輸入框=\(w.firstResponder === tv) 內容=[\(tv.string)] 游標=\(tv.selectedRange().location)/\((tv.string as NSString).length)")
                fflush(stdout)
            }
        }
        // SHOWORK_TEST_SHOT=<png>：等 SHOWORK_TEST_SHOT_DELAY 秒（預設 4）存一張截圖（視窗在螢幕外，外部截圖工具拍不到）
        if let out = ProcessInfo.processInfo.environment["SHOWORK_TEST_SHOT"] {
            let delay = Double(ProcessInfo.processInfo.environment["SHOWORK_TEST_SHOT_DELAY"] ?? "") ?? 4
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                print(BoardWindow.shared.snapshot(to: out) ? "shot saved \(out)" : "shot failed"); fflush(stdout)
            }
        }
        NSApplication.shared.run()
    }
}

// Test: ShoWorkAgent --board-act <approve|park|sendback|review> <sessionId> [文字]
//       ShoWorkAgent --board-act answer <sessionId> <文字>   3D 辦公室直接回答（tmux→直送→拷貝）
//       ShoWorkAgent --board-act newtask <資料夾> <提示>      e2e 驗收用，跟按鈕走同一條路
//       ShoWorkAgent --board-act captain <文字>              交給隊長（隊長不在就開背景隊長），跟收件匣同一條路
if argv.count >= 4, argv[1] == "--board-act", argv[2] == "captain" {
    print(BoardActions.askCaptain(argv[3]))
    exit(0)
}
if argv.count >= 3, argv[1] == "--board-act" {
    MainActor.assumeIsolated {
        if argv[2] == "newtask", argv.count >= 5 {
            switch BoardActions.newTask(folder: argv[3], prompt: argv[4], fullAuto: false) {
            case .success(let id): print("bg", id); exit(0)
            case .failure(let e): print("error", e.message); exit(1)
            }
        }
        let s = BoardReader().read()
        let fm = FileManager.default
        let cards = Board.build(sessions: s.sessions, transcripts: s.transcripts, glows: s.glows, teams: s.teams, inbox: s.inbox,
                                reports: s.reports, reviews: s.reviews, decisions: s.decisions, contexts: s.contexts, nicknames: s.nicknames,
                                now: Date(), home: BoardPaths.home, isRepo: { fm.fileExists(atPath: $0 + "/.git") })
        guard argv.count >= 4, let c = cards.first(where: { $0.id == argv[3] }) else { print("no such card"); exit(1) }
        let text = argv.count >= 5 ? argv[4] : ""
        switch argv[2] {
        case "approve": BoardActions.approve(c); print("ok"); exit(0)
        case "wrapup": print(BoardActions.wrapUp(c)); exit(0)
        case "answer": print(BoardActions.answer(c, text: text)); exit(0)
        case "park": BoardActions.park(c, note: text); print("ok"); exit(0)
        case "sendback":
            switch BoardActions.sendBack(c, text: text) { case .typed: print("typed"); case .copied(let m): print("copied", m) }
            exit(0)
        case "review":
            Reviewer.shared.start(c, force: true)
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { if !Reviewer.shared.isRunning(c.sessionId) { print("reviewed"); exit(0) } }
            }
            NSApplication.shared.run()
        default: print("unknown action"); exit(1)
        }
    }
}

// 不認得的 --參數 一律結束，不要當成正式 agent 跑起來（10-08：舊版不認得 --board-dump，
// 結果多開一個 agent 把正式 agent 的 socket 搶走）
if argv.count >= 2, argv[1].hasPrefix("--") {
    FileHandle.standardError.write(Data("ShoWorkAgent: unknown option \(argv[1])\n".utf8)); exit(2)
}

// Accessibility is required (window frames, focus, key/click monitor). Under launchd, exiting here
// would respawn-loop, so ask ONCE (system prompt) and then wait quietly until it is granted.
if !AXIsProcessTrusted() {
    FileHandle.standardError.write(Data("ShoWorkAgent: waiting for Accessibility permission (System Settings → Privacy & Security → Accessibility → ShoWorkAgent)\n".utf8))
    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    // AXIsProcessTrusted() can keep answering false inside this process even after the user flips the
    // switch (seen 09-26). Ask TCC fresh through a short-lived child instead, then re-exec ourselves.
    while true {
        Thread.sleep(forTimeInterval: 2)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        p.arguments = ["--ax-check"]
        try? p.run(); p.waitUntilExit()
        if p.terminationStatus == 0 { break }
    }
    FileHandle.standardError.write(Data("ShoWorkAgent: Accessibility granted — restarting to pick it up\n".utf8))
    let args = CommandLine.arguments.map { strdup($0) } + [nil]
    execv(CommandLine.arguments[0], args)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)                       // no Dock icon, no menu bar
    EditMenu.install()                                        // 聽寫（按兩下 Control）、⌘C／⌘V 的快捷鍵要掛在編輯選單上（EditMenu.swift）
    let engine = Engine()
    engine.start()
    let titles = TitleWatcher(engine: engine)
    titles.start()
    Menu.shared.install()
    // lets tests / scripts open the settings panel without driving the menu (09-26: a blind Return in
    // the status menu hit「結束 ShoWork42」)
    DistributedNotificationCenter.default().addObserver(forName: Notification.Name("ai.okle42.showork.showSettings"),
                                                        object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { SettingsPanel.shared.show() }
    }
    DistributedNotificationCenter.default().addObserver(forName: Notification.Name("ai.okle42.showork.showBoard"),
                                                        object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { BoardWindow.shared.show() }
    }
    Arranger.shared.start()
    BoardModel.shared.start()          // 戰情中心的資料（審核、ctx 收尾）視窗沒開也要跑
    NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { BoardWindow.terminating = true }
    }
    if BoardWindow.wasOpen {           // 上次開著 ⇒ 重啟後照樣打開（等 run loop 起來再開視窗，見已知坑 11）
        DispatchQueue.main.async { MainActor.assumeIsolated { BoardWindow.shared.show() } }
    }
    let server = Server { m in DispatchQueue.main.async { MainActor.assumeIsolated { engine.handle(m) } } }
    do { try server.start() } catch {
        FileHandle.standardError.write(Data("ShoWorkAgent: cannot open socket at \(Paths.socket.path): \(error)\n".utf8))
        exit(1)
    }
    FileHandle.standardError.write(Data("ShoWorkAgent listening on \(Paths.socket.path)\n".utf8))
    withExtendedLifetime((server, titles)) { app.run() }
}
