import AppKit
import ShoWorkCore

let argv = CommandLine.arguments

// Debug: ShoWorkAgent --arrange-dry   → prints the frames it WOULD apply (moves nothing)
if argv.count == 2, argv[1] == "--arrange-dry" {
    MainActor.assumeIsolated {
        let a = Arranger.shared
        let p = a.plan()
        print("area", a.mainAreaAX(), "windows", p.count)
        for (t, f) in p { print(t.app, AXQuery.wid(t.el), "now", t.frame, "→", f) }
        exit(0)
    }
}
// Test: ShoWorkAgent --arrange-once [columns|grid]  → arrange current Space once, print "wid x y w h" planned, exit
if argv.count >= 2, argv[1] == "--arrange-once" {
    MainActor.assumeIsolated {
        let a = Arranger.shared
        if argv.count == 3, let s = LayoutPlan.FourStyle(rawValue: argv[2]) { a.fourStyle = s }
        let p = a.plan()
        a.arrange()
        for (t, f) in p { print(AXQuery.wid(t.el), Int(f.minX), Int(f.minY), Int(f.width), Int(f.height)) }
        exit(0)
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
    while !AXIsProcessTrusted() { Thread.sleep(forTimeInterval: 2) }
    FileHandle.standardError.write(Data("ShoWorkAgent: Accessibility granted\n".utf8))
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)                       // no Dock icon, no menu bar
    let engine = Engine()
    engine.start()
    Menu.shared.install()
    Arranger.shared.start()
    let server = Server { m in DispatchQueue.main.async { MainActor.assumeIsolated { engine.handle(m) } } }
    do { try server.start() } catch {
        FileHandle.standardError.write(Data("ShoWorkAgent: cannot open socket at \(Paths.socket.path): \(error)\n".utf8))
        exit(1)
    }
    FileHandle.standardError.write(Data("ShoWorkAgent listening on \(Paths.socket.path)\n".utf8))
    withExtendedLifetime(server) { app.run() }
}
