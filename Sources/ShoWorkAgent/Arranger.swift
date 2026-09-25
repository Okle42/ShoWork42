import AppKit
import Carbon.HIToolbox
import ShoWorkCore

/// Arranges every terminal window (Ghostty / Terminal / iTerm2) on the main screen.
/// Keng 09-26: all terminal windows; auto on count change (can be switched off); ⌃⌥L now;
/// with 4 windows ⌃⌥L toggles columns ⇄ 2×2.
@MainActor
final class Arranger {
    static let shared = Arranger()

    private let defaults = UserDefaults(suiteName: "ai.okle42.showork") ?? .standard
    var autoArrange: Bool {
        get { defaults.object(forKey: "autoArrange") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoArrange"); Menu.shared.refresh() }
    }
    var fourStyle: LayoutPlan.FourStyle {
        get { LayoutPlan.FourStyle(rawValue: defaults.string(forKey: "fourStyle") ?? "") ?? .columns }
        set { defaults.set(newValue.rawValue, forKey: "fourStyle"); Menu.shared.refresh() }
    }

    private var lastCount = -1
    private var pending: DispatchWorkItem?
    private var poll: Timer?

    struct Target { let app: TerminalApp; let pid: pid_t; let el: AXUIElement; let frame: CGRect }

    func start() {
        HotKey.register(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            MainActor.assumeIsolated { self?.hotkey() }
        }
        // cheap count check (CG window list, no AX) — a new/closed window re-arranges after 0.8 s
        poll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkCount() }
        }
        lastCount = targets().count
    }

    func hotkey() {
        if targets().count == 4 { fourStyle = fourStyle == .columns ? .grid : .columns }
        arrange()
    }

    private func checkCount() {
        guard autoArrange else { lastCount = -1; return }
        let n = quickCount()
        guard n != lastCount else { return }
        lastCount = n
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.arrange(); self?.lastCount = self?.quickCount() ?? -1 } }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: w)
    }

    /// Number of normal, on-screen terminal windows (layer 0) — no AX calls.
    func quickCount() -> Int {
        let pids = Set(runningTerminals().map(\.1))
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        return list.filter {
            guard let p = $0[kCGWindowOwnerPID as String] as? pid_t, pids.contains(p),
                  ($0[kCGWindowLayer as String] as? Int) == 0,
                  let b = $0[kCGWindowBounds as String] as? [String: Any],
                  (b["Width"] as? Double ?? 0) > 200, (b["Height"] as? Double ?? 0) > 120 else { return false }
            return true
        }.count
    }

    private func runningTerminals() -> [(TerminalApp, pid_t)] {
        [TerminalApp.ghostty, .terminal, .iterm].flatMap { app in
            NSRunningApplication.runningApplications(withBundleIdentifier: app.rawValue).map { (app, $0.processIdentifier) }
        }
    }

    /// Normal windows only: standard subrole, not minimized, not full screen, on this Space, on the main screen.
    func targets() -> [Target] {
        let main = mainAreaAX()
        return runningTerminals().flatMap { app, pid in
            AXQuery.windows(ofPID: pid).compactMap { el -> Target? in
                guard AXQuery.string(el, kAXSubroleAttribute) == kAXStandardWindowSubrole as String,
                      !axBool(el, kAXMinimizedAttribute), !axBool(el, "AXFullScreen"),
                      WindowList.onScreen(AXQuery.wid(el)),
                      let f = axFrame(el), main.insetBy(dx: -200, dy: -200).contains(CGPoint(x: f.midX, y: f.midY)) else { return nil }
                return Target(app: app, pid: pid, el: el, frame: f)
            }
        }
    }

    /// Visible frame of the main screen (menu bar and Dock excluded) in AX top-left coordinates.
    func mainAreaAX() -> CGRect {
        guard let s = NSScreen.screens.first else { return .zero }
        let v = s.visibleFrame, H = s.frame.height
        return CGRect(x: v.minX, y: H - v.maxY, width: v.width, height: v.height)
    }

    /// Reading order (top→bottom, left→right) keeps windows near where they were.
    func ordered() -> [Target] {
        targets().sorted {
            let ra = ($0.frame.minY / 80).rounded(), rb = ($1.frame.minY / 80).rounded()
            return ra != rb ? ra < rb : $0.frame.minX < $1.frame.minX
        }
    }

    func plan() -> [(Target, CGRect)] {
        let ts = ordered()
        return Array(zip(ts, LayoutPlan.frames(count: ts.count, in: mainAreaAX(), four: fourStyle)))
    }

    func arrange() {
        let pairs = plan()
        let ts = pairs.map(\.0)
        let frames = pairs.map(\.1)
        for (t, f) in zip(ts, frames) {
            set(t.el, position: f.origin); set(t.el, size: f.size); set(t.el, position: f.origin)   // size can nudge origin
        }
        // later windows on top so staggered title bars stay visible (per app; cross-app order is the user's)
        for t in ts { AXUIElementPerformAction(t.el, kAXRaiseAction as CFString) }
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let fw = Selection.focusedWID(pid: front), let el = ts.first(where: { AXQuery.wid($0.el) == fw })?.el {
            AXUIElementPerformAction(el, kAXRaiseAction as CFString)       // keep the window you're in on top
        }
    }

    // MARK: AX helpers
    private func axBool(_ el: AXUIElement, _ a: String) -> Bool {
        var v: CFTypeRef?; AXUIElementCopyAttributeValue(el, a as CFString, &v); return (v as? Bool) ?? false
    }
    private func axFrame(_ el: AXUIElement) -> CGRect? {
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p); AXValueGetValue(sv as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }
    private func set(_ el: AXUIElement, position p: CGPoint) {
        var v = p; if let a = AXValueCreate(.cgPoint, &v) { AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, a) }
    }
    private func set(_ el: AXUIElement, size s: CGSize) {
        var v = s; if let a = AXValueCreate(.cgSize, &v) { AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, a) }
    }
}

extension WindowList {
    static func onScreen(_ wid: CGWindowID) -> Bool {
        (CGWindowListCopyWindowInfo([.optionIncludingWindow], wid) as? [[String: Any]])?.first?[kCGWindowIsOnscreen as String] as? Bool ?? false
    }
}

// MARK: - global hotkey (Carbon; needs no extra permission)

enum HotKey {
    nonisolated(unsafe) private static var handlers: [UInt32: () -> Void] = [:]
    nonisolated(unsafe) private static var installed = false

    static func register(keyCode: UInt32, modifiers: UInt32, _ handler: @escaping () -> Void) {
        let id = UInt32(handlers.count + 1)
        handlers[id] = handler
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &hk)
                HotKey.handlers[hk.id]?()
                return noErr
            }, 1, &spec, nil, nil)
        }
        var ref: EventHotKeyRef?
        RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: OSType(0x5357_3432), id: id), GetApplicationEventTarget(), 0, &ref)
    }
}

// MARK: - menu bar item (the agent's only UI)

@MainActor
final class Menu: NSObject {
    static let shared = Menu()
    private var item: NSStatusItem?
    private let menu = NSMenu()

    func install() {
        let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        i.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "ShoWork42")
        i.button?.image?.isTemplate = true
        i.menu = menu
        item = i
        refresh()
    }

    func refresh() {
        guard item != nil else { return }
        menu.removeAllItems()
        let a = Arranger.shared
        menu.addItem(withTitle: "立即排版", action: #selector(arrangeNow), keyEquivalent: "l").keyEquivalentModifierMask = [.control, .option]
        let auto = menu.addItem(withTitle: "視窗數量變動時自動排版", action: #selector(toggleAuto), keyEquivalent: "")
        auto.state = a.autoArrange ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "4 個視窗時：", action: nil, keyEquivalent: "").isEnabled = false
        let c = menu.addItem(withTitle: "　四等分直欄", action: #selector(fourColumns), keyEquivalent: ""); c.state = a.fourStyle == .columns ? .on : .off
        let g = menu.addItem(withTitle: "　上下左右 2×2", action: #selector(fourGrid), keyEquivalent: ""); g.state = a.fourStyle == .grid ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "結束 ShoWork42", action: #selector(quit), keyEquivalent: "")
        menu.items.forEach { if $0.action != nil { $0.target = self } }
    }

    @objc private func arrangeNow() { Arranger.shared.arrange() }
    @objc private func toggleAuto() { Arranger.shared.autoArrange.toggle() }
    @objc private func fourColumns() { Arranger.shared.fourStyle = .columns; Arranger.shared.arrange() }
    @objc private func fourGrid() { Arranger.shared.fourStyle = .grid; Arranger.shared.arrange() }
    @objc private func quit() { NSApp.terminate(nil) }
}
