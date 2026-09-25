import AppKit
import ShoWorkCore

// Debug: ShoWorkAgent --resolve /dev/ttysNNN   → prints "<app> <pid> <wid> <tabTTY>" per placement
let argv = CommandLine.arguments
if argv.count == 3, argv[1] == "--resolve" {
    MainActor.assumeIsolated {
        let r = Resolver().placements(for: argv[2])
        if r.isEmpty { print("none"); exit(1) }
        for p in r { print(p.app, p.pid, p.wid, p.tabTTY) }
        exit(0)
    }
}
print("ShoWorkAgent: server pending (M1-2b)")
