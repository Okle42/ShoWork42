import AppKit
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
    Arranger.shared.start()
    let server = Server { m in DispatchQueue.main.async { MainActor.assumeIsolated { engine.handle(m) } } }
    do { try server.start() } catch {
        FileHandle.standardError.write(Data("ShoWorkAgent: cannot open socket at \(Paths.socket.path): \(error)\n".utf8))
        exit(1)
    }
    FileHandle.standardError.write(Data("ShoWorkAgent listening on \(Paths.socket.path)\n".utf8))
    withExtendedLifetime((server, titles)) { app.run() }
}
