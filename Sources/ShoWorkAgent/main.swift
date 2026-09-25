import AppKit
import ShoWorkCore

let argv = CommandLine.arguments

// Debug: ShoWorkAgent --resolve /dev/ttysNNN   → "<app> <pid> <wid> <tabTTY>" per placement
if argv.count == 3, argv[1] == "--resolve" {
    MainActor.assumeIsolated {
        let r = Resolver().placements(for: argv[2])
        if r.isEmpty { print("none"); exit(1) }
        for p in r { print(p.app, p.pid, p.wid, p.tabTTY) }
        exit(0)
    }
}

guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("ShoWorkAgent needs Accessibility permission (System Settings → Privacy & Security → Accessibility).\n".utf8))
    exit(2)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)                       // no Dock icon, no menu bar
    let engine = Engine()
    engine.start()
    let server = Server { m in DispatchQueue.main.async { MainActor.assumeIsolated { engine.handle(m) } } }
    do { try server.start() } catch {
        FileHandle.standardError.write(Data("ShoWorkAgent: cannot open socket at \(Paths.socket.path): \(error)\n".utf8))
        exit(1)
    }
    FileHandle.standardError.write(Data("ShoWorkAgent listening on \(Paths.socket.path)\n".utf8))
    withExtendedLifetime(server) { app.run() }
}
