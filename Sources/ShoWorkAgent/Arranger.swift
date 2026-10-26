import AppKit
import Carbon.HIToolbox
import ShoWorkCore

/// Arranges every terminal window (Ghostty / Terminal / iTerm2), each screen on its own.
/// Kang 09-26: all terminal windows; auto on count change (can be switched off); ⌃⌥L now;
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
    /// Windows placed by the last overlapping layout, with their row (0 = top). Drives restacking.
    private(set) var arranged: [(wid: CGWindowID, pid: pid_t, el: AXUIElement, row: Int, screen: Int)] = []
    private var restacking = false
    private var focusObservers: [pid_t: AXObserver] = [:]
    private var pending: DispatchWorkItem?
    private var poll: Timer?

    struct Target { let app: TerminalApp; let pid: pid_t; let el: AXUIElement; let frame: CGRect; let screen: Int }

    func start() {
        HotKey.register(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            MainActor.assumeIsolated { self?.hotkey() }
        }
        // cheap count check (CG window list, no AX) — a new/closed window re-arranges after 0.8 s
        poll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkCount() }
        }
        lastCount = targets().count
        watchFocus()
        NotificationCenter.default.addObserver(forName: Notification.Name("sw42.focus"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.focusChanged() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchFocus(); self?.focusChanged() }
        }
    }

    func hotkey() {
        if Dictionary(grouping: targets(), by: \.screen).values.contains(where: { $0.count == 4 }) { fourStyle = fourStyle == .columns ? .grid : .columns }
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

    /// Normal windows only: standard subrole, not minimized, not full screen, on this Space.
    /// Each window belongs to the screen that holds its centre (nearest screen if it's off all of them).
    func targets() -> [Target] {
        let areas = screenAreasAX()
        guard !areas.isEmpty else { return [] }
        return runningTerminals().flatMap { app, pid in
            AXQuery.windows(ofPID: pid).compactMap { el -> Target? in
                guard AXQuery.string(el, kAXSubroleAttribute) == kAXStandardWindowSubrole as String,
                      !axBool(el, kAXMinimizedAttribute), !axBool(el, "AXFullScreen"),
                      WindowList.onScreen(AXQuery.wid(el)), let f = axFrame(el) else { return nil }
                return Target(app: app, pid: pid, el: el, frame: f, screen: Arranger.screenIndex(of: f, in: areas))
            }
        }
    }

    static func screenIndex(of f: CGRect, in areas: [CGRect]) -> Int {
        let c = CGPoint(x: f.midX, y: f.midY)
        if let i = areas.firstIndex(where: { $0.contains(c) }) { return i }
        func dist(_ a: CGRect) -> CGFloat { hypot(max(a.minX - c.x, 0, c.x - a.maxX), max(a.minY - c.y, 0, c.y - a.maxY)) }
        return areas.indices.min { dist(areas[$0]) < dist(areas[$1]) } ?? 0
    }

    /// Visible frame of every screen (menu bar and Dock excluded) in AX top-left coordinates
    /// (origin = top-left of the PRIMARY screen, as AX and CGWindowList use).
    func screenAreasAX() -> [CGRect] {
        guard let H = NSScreen.screens.first?.frame.height else { return [] }
        return NSScreen.screens.map { s in
            let v = s.visibleFrame
            return CGRect(x: v.minX, y: H - v.maxY, width: v.width, height: v.height)
        }
    }

    func mainAreaAX() -> CGRect { screenAreasAX().first ?? .zero }

    /// Reading order (top→bottom, left→right) keeps windows near where they were.
    func ordered(_ ts: [Target]) -> [Target] {
        ts.sorted {
            let ra = ($0.frame.minY / 80).rounded(), rb = ($1.frame.minY / 80).rounded()
            return ra != rb ? ra < rb : $0.frame.minX < $1.frame.minX
        }
    }

    /// One independent layout per screen, screens in NSScreen order.
    /// 戰情中心開著的那台螢幕，終端機只排在它旁邊剩下的那一側（Kang 10-08）。
    func plan() -> [(Target, CGRect)] {
        let board = Arranger.boardFrame()
        let screens = screenAreasAX()
        let byScreen = Dictionary(grouping: targets(), by: \.screen)
        return byScreen.keys.sorted().flatMap { i -> [(Target, CGRect)] in
            let ts = ordered(byScreen[i]!)
            let a = LayoutPlan.area(screens[i], avoiding: board)
            // 戰情中心在這台：旁邊那側排成撲克牌；其他螢幕照原本的排法
            let frames = a != screens[i] ? LayoutPlan.cascade(ts.count, in: a) : LayoutPlan.frames(count: ts.count, in: a, four: fourStyle)
            return Array(zip(ts, frames))
        }
    }

    /// 戰情中心視窗在畫面上的位置（AX 座標）；沒開或縮到 Dock 回傳 nil。用視窗清單找，--arrange-dry 也看得到。
    static func boardFrame() -> CGRect? {
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        // 只認自己這個 process 的（10-12：--board-window 測試視窗同名，會被當成看板）。
        // 不比 owner 名稱：10-25 改成 .app 後名稱變成 CFBundleDisplayName「ShoWork42 戰情中心」，比名稱就找不到看板、終端機不再讓位
        guard let w = list.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid()
                                          && ($0[kCGWindowName as String] as? String) == "AI工作戰情中心"
                                          && ($0[kCGWindowLayer as String] as? Int) == 0 }),
              let b = w[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return CGRect(x: b["X"] as? Double ?? 0, y: b["Y"] as? Double ?? 0, width: b["Width"] as? Double ?? 0, height: b["Height"] as? Double ?? 0)
    }

    /// Test mode: SHOWORK_ONLY_WIDS="w1,w2,…" ⇒ refuse to touch ANYTHING if a window outside the
    /// list is on screen (09-26 incident: a test moved Kang's windows). Enforced here, not in scripts.
    static var onlyWIDs: Set<CGWindowID>? {
        ProcessInfo.processInfo.environment["SHOWORK_ONLY_WIDS"].map { Set($0.split(separator: ",").compactMap { CGWindowID($0) }) }
    }

    /// `pairs` lets a caller act on exactly the plan it already showed (a new window still sliding
    /// into place can change the reading order between two plan() calls — M1b n=10 bug).
    @discardableResult
    func arrange(_ given: [(Target, CGRect)]? = nil) -> Bool {
        let pairs = given ?? plan()
        let ts = pairs.map(\.0)
        let frames = pairs.map(\.1)
        if let allow = Arranger.onlyWIDs {
            let foreign = ts.map { AXQuery.wid($0.el) }.filter { !allow.contains($0) }
            guard foreign.isEmpty else {
                FileHandle.standardError.write(Data("REFUSED: windows outside SHOWORK_ONLY_WIDS on screen: \(foreign)\n".utf8))
                return false
            }
        }
        // guard-only mode: everything above ran, nothing below moves a window
        if ProcessInfo.processInfo.environment["SHOWORK_ARRANGE_NOOP"] != nil {
            FileHandle.standardError.write(Data("NOOP: would arrange \(ts.count) windows\n".utf8)); return true
        }
        // shrink first, then move, then size again: moving a tall window low first lets AppKit clamp it
        // to the screen bottom and the later size change doesn't fully take (M1b bug: 567 vs 483)
        for attempt in 0..<3 {
            var wrong = 0
            for (t, f) in zip(ts, frames) {
                guard let cur = axFrame(t.el), !close(cur, f) else { continue }
                wrong += 1
                set(t.el, size: f.size); set(t.el, position: f.origin); set(t.el, size: f.size)
            }
            if wrong == 0 { break }
            if attempt < 2 { usleep(120_000) }                       // some terminals resize asynchronously
        }
        // rows per screen (plan() keeps each screen's windows together, in layout order)
        // 有互相重疊的那幾台螢幕才需要疊放管理（全螢幕 6 個以上、或戰情中心旁的窄區 3 個以上）
        arranged = Dictionary(grouping: pairs, by: \.0.screen).values.flatMap { group -> [(wid: CGWindowID, pid: pid_t, el: AXUIElement, row: Int, screen: Int)] in
            guard let rows = LayoutPlan.overlapRows(of: group.map(\.1)) else { return [] }
            return zip(group.map(\.0), rows).map { (AXQuery.wid($0.el), $0.pid, $0.el, $1, $0.screen) }
        }
        // later windows on top so staggered title bars stay visible (per app; cross-app order is the user's)
        for t in ts { AXUIElementPerformAction(t.el, kAXRaiseAction as CFString) }
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let fw = Selection.focusedWID(pid: front), let el = ts.first(where: { AXQuery.wid($0.el) == fw })?.el {
            AXUIElementPerformAction(el, kAXRaiseAction as CFString)       // keep the window you're in on top
        }
        return true
    }

    /// Origin exact; size may be a little smaller (terminals snap to their character grid), never bigger.
    private func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 &&
        (-25...2).contains(a.width - b.width) && (-25...2).contains(a.height - b.height)
    }

    // MARK: canonical stacking (Kang 09-26: click a bottom window ⇒ middle row re-emerges above top row)

    /// The row you're in goes on top; the closer another row is to yours, the higher it sits
    /// (Kang 09-26: click a top window ⇒ the middle row shows its lower half right beneath it;
    /// click a bottom window ⇒ the middle row re-emerges above the top row). Yours is topmost.
    func restack(focused: CGWindowID) {
        guard !restacking, let me = arranged.first(where: { $0.wid == focused }) else { return }
        restacking = true
        let mine = arranged.filter { $0.screen == me.screen }                 // only the screen you're on
        let isCascade = Set(mine.map(\.row)).count == mine.count             // 撲克牌：一排一張
        let order = mine.sorted {
            if isCascade { return $0.row < $1.row }                           // 撲克牌照原本順序（後面的在上），你點的那張最上面
            let da = abs($0.row - me.row), db = abs($1.row - me.row)          // raise farthest rows first, nearest last
            return da != db ? da > db : $0.row < $1.row
        }
        for w in order where w.wid != focused {
            AXUIElementPerformAction(w.el, kAXRaiseAction as CFString)
        }
        AXUIElementPerformAction(me.el, kAXRaiseAction as CFString)
        // give keyboard focus back to the window you clicked (raising others may have moved it)
        AXUIElementSetAttributeValue(me.el, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(me.pid), kAXFocusedWindowAttribute as CFString, me.el)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.restacking = false }
    }

    /// Watch focus changes in every running terminal app.
    func watchFocus() {
        for (_, pid) in runningTerminals() where focusObservers[pid] == nil {
            var o: AXObserver?
            guard AXObserverCreate(pid, { _, _, _, _ in
                NotificationCenter.default.post(name: Notification.Name("sw42.focus"), object: nil)
            }, &o) == .success, let o else { continue }
            AXObserverAddNotification(o, AXUIElementCreateApplication(pid), kAXFocusedWindowChangedNotification as CFString, nil)
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode)
            focusObservers[pid] = o
        }
    }

    func focusChanged() {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let fw = Selection.focusedWID(pid: front) else { return }
        restack(focused: fw)
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
final class Menu: NSObject, NSMenuDelegate {
    static let shared = Menu()
    private var item: NSStatusItem?
    private let menu = NSMenu()

    func install() {
        let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        i.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "ShoWork42")
        i.button?.image?.isTemplate = true
        i.menu = menu
        menu.delegate = self
        item = i
        refresh()
    }

    /// (state, placement) for every lit tab — set by the Engine after each render
    var summary: [(WorkState, Placement)] = []

    /// Menu bar shows how many windows are purple / green / orange / red; the menu lists them, click to go there.
    /// 10-24 Kang：用 attributedTitle＋variableLength 時，數字變了選單列寬度沒跟上，圓點會疊到隔壁圖示、數字被切掉；
    /// 而且 macOS 26 選單列會把彩色文字洗淡（紫點變白）。⇒ 整顆畫成一張非 template 圖、長度自己算好設定
    private func paintButton() {
        guard let i = item, let b = i.button else { return }
        let counts = [WorkState.working, .done, .waiting, .input].map { s in (s, Set(summary.filter { $0.0 == s }.map(\.1.wid)).count) }
        let lit = counts.filter { $0.1 > 0 }
        b.attributedTitle = NSAttributedString(string: "")
        guard !lit.isEmpty else {
            b.image = Self.icon; b.imagePosition = .imageOnly
            i.length = NSStatusItem.variableLength
            return
        }
        let img = Self.badge(lit.map { (Look.color($0.0), $0.1) })
        b.image = img; b.imagePosition = .imageOnly
        i.length = img.size.width + 8
    }

    private static var icon: NSImage? {
        let im = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "ShoWork42")
        im?.isTemplate = true
        return im
    }

    /// 圖示＋「●n」幾組；文字與圖示用選單列當下的字色（drawingHandler 畫的時候才取色，深淺色選單列都對）
    static func badge(_ groups: [(NSColor, Int)]) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let sym = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        let symW = sym?.size.width ?? 18
        let dot: CGFloat = 8, gap: CGFloat = 3, groupGap: CGFloat = 6
        let nums = groups.map { "\($0.1)" as NSString }
        let numW = nums.map { $0.size(withAttributes: [.font: font]).width }
        let w = ceil(symW + groupGap + zip(groups, numW).map { _, nw in dot + gap + nw }.reduce(0, +) + groupGap * CGFloat(groups.count - 1))
        let h: CGFloat = 18
        let im = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            let fg = NSColor.labelColor
            if let sym {
                let r = NSRect(x: 0, y: (h - sym.size.height) / 2, width: sym.size.width, height: sym.size.height)
                sym.draw(in: r)
                fg.set(); r.fill(using: .sourceAtop)      // template 符號染成字色
            }
            var x = symW + groupGap
            for ((c, _), (n, nw)) in zip(groups, zip(nums, numW)) {
                c.setFill(); NSBezierPath(ovalIn: NSRect(x: x, y: (h - dot) / 2, width: dot, height: dot)).fill()
                x += dot + gap
                let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg]
                n.draw(at: NSPoint(x: x, y: (h - n.size(withAttributes: a).height) / 2), withAttributes: a)
                x += nw + groupGap
            }
            return true
        }
        im.isTemplate = false
        im.accessibilityDescription = "ShoWork42：" + groups.map { "\($0.1)" }.joined(separator: "、")
        return im
    }

    /// 選單列的圖示＋計數每次都畫；選單內容（每個視窗查一次 AX 標題）等你點開才建（10-24 Kang 選 A：原本每個 hook 事件都重建）
    func refresh() {
        guard item != nil else { return }
        paintButton()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

    private func rebuild() {
        menu.removeAllItems()
        let names: [WorkState: String] = [.input: "等你回答", .waiting: "等待中", .done: "已完成", .working: "工作中"]
        var shown = Set<CGWindowID>()
        for s in [WorkState.input, .waiting, .done, .working] {
            for (_, p) in summary.filter({ $0.0 == s }) where !shown.contains(p.wid) {
                shown.insert(p.wid)
                let title = AXQuery.element(pid: p.pid, wid: p.wid).flatMap { AXQuery.string($0, kAXTitleAttribute) } ?? "視窗 \(p.wid)"
                let mi = menu.addItem(withTitle: "\(names[s]!)　\(title)", action: #selector(focusWindow(_:)), keyEquivalent: "")
                mi.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: names[s])?
                    .withSymbolConfiguration(.init(paletteColors: [Look.color(s)]))
                mi.representedObject = [Int(p.pid), Int(p.wid)]
                mi.target = self
            }
        }
        if shown.isEmpty { menu.addItem(withTitle: "目前沒有工作中的 AI 視窗", action: nil, keyEquivalent: "").isEnabled = false }
        menu.addItem(.separator())
        menu.addItem(withTitle: "AI工作戰情中心⋯", action: #selector(openBoard), keyEquivalent: "")
        let a = Arranger.shared
        menu.addItem(withTitle: "立即排版", action: #selector(arrangeNow), keyEquivalent: "l").keyEquivalentModifierMask = [.control, .option]
        menu.addItem(withTitle: "設定⋯", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "結束 ShoWork42", action: #selector(quit), keyEquivalent: "")
        menu.items.forEach { if $0.action != nil && $0.target == nil { $0.target = self } }
    }

    @objc private func focusWindow(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? [Int], v.count == 2,
              let el = AXQuery.element(pid: pid_t(v[0]), wid: CGWindowID(v[1])) else { return }
        NSRunningApplication(processIdentifier: pid_t(v[0]))?.activate()
        AXUIElementPerformAction(el, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(el, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    @objc private func arrangeNow() { Arranger.shared.arrange() }
    @objc private func openSettings() { SettingsPanel.shared.toggle() }
    @objc private func openBoard() { BoardWindow.shared.show() }
    @objc private func quit() { NSApp.terminate(nil) }
}
