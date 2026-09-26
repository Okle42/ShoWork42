import AppKit
import ShoWorkCore

/// Everything the agent knows, driven on the main thread.
@MainActor
final class Engine {
    struct Tab { var state: WorkState; var agentPID: pid_t; var agent: String; var placements: [Placement] }

    private let resolver = Resolver()
    private(set) var tabs: [String: Tab] = [:]              // key: AI tty (pane tty for tmux)
    private var glows: [CGWindowID: Glow] = [:]
    private let edge = EdgeGlow()
    private var watchdog: Timer?
    private var reaper: Timer?

    // MARK: persistence — an agent restart (update, crash) must not forget who is working
    private var stateURL: URL { Paths.supportDir.appendingPathComponent("state.json") }
    private struct Saved: Codable { let tty: String; let state: WorkState; let pid: Int32; let agent: String }

    private func save() {
        let s = tabs.map { Saved(tty: $0.key, state: $0.value.state, pid: $0.value.agentPID, agent: $0.value.agent) }
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: stateURL, options: .atomic) }
    }

    private func restore() {
        guard let d = try? Data(contentsOf: stateURL), let s = try? JSONDecoder().decode([Saved].self, from: d) else { return }
        for x in s where ProcTree.alive(x.pid) && x.state != .idle {
            let p = resolver.placements(for: x.tty)
            tabs[x.tty] = Tab(state: x.state, agentPID: x.pid, agent: x.agent, placements: p)
            Log.note("RESTORE \(x.tty) \(x.state.rawValue) → \(p.map { "\($0.app)#\($0.wid)" })")
        }
        render()
    }

    func start() {
        restore()
        // ONE watchdog for all glows (M0: one per glow cost 0.13% each)
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkStacking() }
        }
        reaper = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reapDeadAgents() }
        }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            // the activated app re-stacks all its windows a beat later (M0 ③)
            for t in [0.05, 0.25, 0.6] {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated { self?.syncAll(); self?.acknowledgeLooked() } }
            }
        }
        nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            for t in [0.0, 0.3, 0.8] {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated { self?.syncAll(); self?.updateEdge() } }
            }
        }
        ClearWatcher.shared.onUserActivity = { [weak self] in self?.acknowledgeLooked() }
        NotificationCenter.default.addObserver(forName: GlowSettings.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.glows.values.forEach { $0.restyle() }; self?.render() }
        }
        ClearWatcher.shared.start()
    }

    // MARK: events

    /// ttys that ever sent a real hook event — the title fallback leaves them alone
    private(set) var hookTTYs = Set<String>()

    func handle(_ m: WireMessage) {
        if m.agent != "claude-title" { hookTTYs.insert(m.tty) }
        var tab = tabs[m.tty] ?? Tab(state: .idle, agentPID: m.pid, agent: m.agent, placements: [])
        tab.agentPID = m.pid; tab.agent = m.agent
        if m.event != .clear {
            let p = resolver.placements(for: m.tty, refresh: tab.placements.isEmpty)
            if !p.isEmpty { tab.placements = p }
        }
        let looking = tab.placements.contains { Selection.isLooking(at: $0) }
        tab.state = StateMachine.next(tab.state, on: m.event, userIsLooking: looking)
        tabs[m.tty] = tab.state == .idle ? nil : tab
        if tab.state == .idle { resolver.forget(m.tty) }
        Log.event(m, looking: looking, result: tab.state, placements: tab.placements)
        render()
    }

    /// The user looked (focus change, key, click). Clear green on every tab they can now see.
    func acknowledgeLooked() {
        var changed = false
        for (tty, t) in tabs where t.state.needsAcknowledgement {
            guard let seen = t.placements.first(where: { Selection.isLooking(at: $0) }) else { continue }
            let n = StateMachine.acknowledge(t.state)
            if n != t.state {
                let front = NSWorkspace.shared.frontmostApplication
                Log.note("ACK \(tty) \(t.state.rawValue)→\(n.rawValue) because looking at \(seen.app)#\(seen.wid); front=\(front?.localizedName ?? "?") focused=\(front.flatMap { Selection.focusedWID(pid: $0.processIdentifier) }.map(String.init) ?? "nil")")
            }
            if n != t.state { changed = true; tabs[tty] = n == .idle ? nil : Tab(state: n, agentPID: t.agentPID, agent: t.agent, placements: t.placements) }
        }
        if changed { render() }
    }

    private func reapDeadAgents() {
        let dead = tabs.filter { !ProcTree.alive($0.value.agentPID) }.map(\.key)
        guard !dead.isEmpty else { return }
        for d in dead { Log.note("REAP \(d) \(tabs[d]?.state.rawValue ?? "?") agent pid \(tabs[d]?.agentPID ?? 0) is gone") }
        dead.forEach { tabs[$0] = nil; resolver.forget($0) }
        render()
    }

    // MARK: rendering

    /// window state = the most urgent of its tabs (red > green > purple)
    func windowStates() -> [CGWindowID: (WorkState, pid_t)] {
        var out: [CGWindowID: (WorkState, pid_t)] = [:]
        // a state switched off in settings doesn't light anything; the window shows its next lit state
        for t in tabs.values where GlowSettings.shared.look(t.state).enabled { for p in t.placements {
            let cur = out[p.wid]?.0 ?? .idle
            out[p.wid] = (StateMachine.windowState([cur, t.state]), p.pid)
        } }
        return out
    }

    private func render() {
        let want = windowStates()
        for (wid, g) in glows where want[wid] == nil { g.tearDown(); glows[wid] = nil }
        for (wid, (s, pid)) in want {
            let g = glows[wid] ?? Glow(wid: wid, pid: pid)
            glows[wid] = g
            g.state = s
        }
        updateEdge()
        save()
        Menu.shared.summary = tabs.values.flatMap { t in t.placements.map { (t.state, $0) } }
        Menu.shared.refresh()
        StatusFile.write(tabs: tabs, glows: glows)
    }

    private func syncAll() { glows.values.forEach { $0.sync() } }

    private func checkStacking() {
        let order = ((CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? [])
            .map { $0[kCGWindowNumber as String] as? Int ?? -1 }
        for g in glows.values where g.state != .idle {
            if let ti = order.firstIndex(of: Int(g.wid)) {
                if order.firstIndex(of: g.overlayNumber) != ti + 1 || order.firstIndex(of: g.barNumber) != ti - 1 { g.sync() }
            } else if g.overlayVisible { g.sync() }
        }
        updateEdge()
    }

    /// Full-screen Space in front ⇒ the other windows' glows are invisible. Show the most urgent
    /// green/red among windows that are NOT on screen as a thin screen-edge line.
    private func updateEdge() {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let fw = Selection.focusedWID(pid: front),
              let el = AXQuery.element(pid: front, wid: fw) else { edge.hide(); return }
        var v: CFTypeRef?; AXUIElementCopyAttributeValue(el, "AXFullScreen" as CFString, &v)
        guard (v as? Bool) == true else { edge.hide(); return }
        let hidden = glows.values.filter { $0.wid != fw && $0.state.needsAcknowledgement && !$0.targetOnScreen }
        let s = StateMachine.windowState(hidden.map(\.state))
        if s.needsAcknowledgement, let screen = NSScreen.main { edge.show(s, on: screen) } else { edge.hide() }
    }
}

// MARK: - clear triggers: focus changes, and key/click inside the frontmost window

@MainActor
final class ClearWatcher {
    static let shared = ClearWatcher()
    var onUserActivity: () -> Void = {}
    private var monitor: Any?
    private var last = Date.distantPast

    func start() {
        // listen-only; keyDown needs Accessibility trust, which the agent already requires
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Date().timeIntervalSince(self.last) > 0.25 else { return }   // debounce typing
                self.last = Date()
                self.onUserActivity()
            }
        }
    }
}

// MARK: - status file (for tests and the M2 status tool); never read by anything critical

enum StatusFile {
    @MainActor static func write(tabs: [String: Engine.Tab], glows: [CGWindowID: Glow]) {
        guard let path = ProcessInfo.processInfo.environment["SHOWORK_STATUS_FILE"] else { return }
        let t = tabs.map { ["tty": $0.key, "state": $0.value.state.rawValue, "agent": $0.value.agent,
                            "wids": $0.value.placements.map { Int($0.wid) }] as [String: Any] }
        let g = glows.values.map { ["target": Int($0.wid), "overlay": $0.overlayNumber, "state": $0.state.rawValue, "pad": Int(Look.pad)] as [String: Any] }
        if let d = try? JSONSerialization.data(withJSONObject: ["tabs": t, "glows": g], options: [.sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}

enum Log {
    static func note(_ s: String) {
        guard ProcessInfo.processInfo.environment["SHOWORK_DEBUG"] != nil else { return }
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        FileHandle.standardError.write(Data("[\(f.string(from: Date()))] \(s)\n".utf8))
    }
    static func event(_ m: WireMessage, looking: Bool, result: WorkState, placements: [Placement]) {
        guard ProcessInfo.processInfo.environment["SHOWORK_DEBUG"] != nil else { return }
        let ws = placements.map { "\($0.app)#\($0.wid)" }.joined(separator: ",")
        note("EVT \(m.agent) \(m.tty) pid=\(m.pid) \(m.event.rawValue) looking=\(looking) → \(result.rawValue) [\(ws)]")
    }
}
