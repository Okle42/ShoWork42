import AppKit
import QuartzCore
import ShoWorkCore

// MARK: - Look (Keng: soft outer glow ≈12pt; purple breathing, gold steady, red pulsing)

enum Look {
    static let pad: CGFloat = 34            // overlay extends this far beyond the window
    static let spread: CGFloat = 18         // visible soft glow (Keng 09-26: "要更明顯")
    static let corner: CGFloat = 12

    static func color(_ s: WorkState) -> NSColor {
        switch s {
        case .working: NSColor(srgbRed: 0.62, green: 0.40, blue: 1.00, alpha: 1)   // purple
        case .done:    NSColor(srgbRed: 1.00, green: 0.76, blue: 0.24, alpha: 1)   // gold
        case .input:   NSColor(srgbRed: 1.00, green: 0.25, blue: 0.25, alpha: 1)   // red
        case .idle:    .clear
        }
    }
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// Soft glow ring: a crisp 1.5pt edge plus a wide low-alpha halo, both hugging the window outline.
final class GlowView: NSView {
    private let halo = CAShapeLayer()
    private let edge = CAShapeLayer()
    private(set) var state: WorkState = .idle

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [halo, edge] { l.fillColor = nil; l.shadowOffset = .zero; layer?.addSublayer(l) }
        halo.lineWidth = 10; halo.shadowRadius = Look.spread; halo.shadowOpacity = 1
        edge.lineWidth = 2.5; edge.shadowRadius = 5; edge.shadowOpacity = 1
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let path = CGPath(roundedRect: bounds.insetBy(dx: Look.pad - 1, dy: Look.pad - 1),
                          cornerWidth: Look.corner, cornerHeight: Look.corner, transform: nil)
        for l in [halo, edge] { l.frame = bounds; l.path = path }
    }

    func apply(_ s: WorkState) {
        guard s != state else { return }
        state = s
        let c = Look.color(s).cgColor
        halo.strokeColor = Look.color(s).withAlphaComponent(0.55).cgColor; halo.shadowColor = c
        edge.strokeColor = Look.color(s).withAlphaComponent(0.95).cgColor; edge.shadowColor = c
        layer?.removeAllAnimations(); halo.removeAllAnimations(); edge.removeAllAnimations()
        guard !Look.reduceMotion else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.autoreverses = true; a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        switch s {
        case .working: a.fromValue = 1.0; a.toValue = 0.6; a.duration = 1.6    // slow breath, never faint
        case .input:   a.fromValue = 1.0; a.toValue = 0.45; a.duration = 0.6   // urgent pulse
        default: return                                                         // gold: steady
        }
        layer?.add(a, forKey: "pulse")
    }
}

/// AppKit pushes windows out from under the menu bar; for a window hugging the top that shifts the
/// whole ring (M0 ⑦ bug). The part under the menu bar is simply covered by it.
final class GlowWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - One glow per target window

@MainActor
final class Glow {
    let wid: CGWindowID
    let pid: pid_t
    private var window: GlowWindow
    private var view: GlowView { window.contentView as! GlowView }
    /// Inner light: sits directly ABOVE the target, all four edges. In overlapping layouts the outer
    /// ring hides under neighbours; the inner light stays on the window's own visible part (09-26).
    private var bar: GlowWindow = Glow.makeBar()
    var barNumber: Int { bar.windowNumber }
    private var axWin: AXUIElement?
    private var observer: AXObserver?
    private var hotTimer: Timer?
    private var lastFrame: CGRect = .null
    private var stillSince = Date()
    var state: WorkState = .idle { didSet { view.apply(state); barState = nil; sync() } }
    private var barState: WorkState?

    init(wid: CGWindowID, pid: pid_t) {
        self.wid = wid; self.pid = pid
        window = Glow.makeWindow()
        axWin = AXQuery.element(pid: pid, wid: wid)
        observe()
    }

    static let barHeight: CGFloat = 10
    static func makeBar() -> GlowWindow {
        let w = GlowWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.managed, .ignoresCycle, .fullScreenNone]
        let v = NSView(); v.wantsLayer = true
        w.contentView = v
        return w
    }
    /// Inner light on ALL four edges (Keng 09-26: the top had light inside and out, the other sides only
    /// outside — make every side the same). A stroked rounded rect whose glow is clipped to the window,
    /// drawn in a click-through window directly above the target.
    private func paintBar(_ s: WorkState) {
        guard let l = bar.contentView?.layer else { return }
        l.masksToBounds = true
        l.sublayers?.forEach { $0.removeFromSuperlayer() }
        l.removeAllAnimations()
        guard s != .idle else { return }
        let c = Look.color(s)
        let ring = CAShapeLayer()
        ring.frame = CGRect(origin: .zero, size: bar.frame.size)
        ring.path = CGPath(roundedRect: ring.frame.insetBy(dx: 1.5, dy: 1.5), cornerWidth: Look.corner - 1,
                           cornerHeight: Look.corner - 1, transform: nil)
        ring.fillColor = nil
        ring.strokeColor = c.withAlphaComponent(0.95).cgColor
        ring.lineWidth = 3
        ring.shadowColor = c.cgColor; ring.shadowRadius = 8; ring.shadowOpacity = 1; ring.shadowOffset = .zero
        l.addSublayer(ring)
        guard !Look.reduceMotion, s != .done else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.autoreverses = true; a.repeatCount = .infinity
        a.fromValue = 1.0; a.toValue = s == .input ? 0.45 : 0.6; a.duration = s == .input ? 0.6 : 1.6
        l.add(a, forKey: "pulse")
    }

    static func makeWindow() -> GlowWindow {
        let w = GlowWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
        w.ignoresMouseEvents = true                        // never blocks a click, ever
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.managed, .ignoresCycle, .fullScreenNone]
        w.contentView = GlowView(frame: .zero)
        return w
    }

    func tearDown() {
        hotTimer?.invalidate()
        if let o = observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode) }
        window.orderOut(nil); window.close()
        bar.orderOut(nil); bar.close()
    }

    private func observe() {
        guard let axWin else { return }
        var o: AXObserver?
        let ref = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverCreate(pid, { _, _, note, refcon in
            guard let refcon else { return }
            let g = Unmanaged<Glow>.fromOpaque(refcon).takeUnretainedValue()
            let moved = (note as String) == kAXMovedNotification || (note as String) == kAXResizedNotification
            MainActor.assumeIsolated { moved ? g.startHotFollow() : g.sync() }
        }, &o) == .success, let o else { return }
        for n in [kAXMovedNotification, kAXResizedNotification, kAXWindowMiniaturizedNotification,
                  kAXWindowDeminiaturizedNotification, kAXUIElementDestroyedNotification] {
            AXObserverAddNotification(o, axWin, n as CFString, ref)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode)
        observer = o
    }

    /// While the window is being dragged/resized, AX notifications are too sparse (M0: 18pt lag).
    /// Follow at 60 Hz until the frame has been still for 0.3 s.
    func startHotFollow() {
        sync()
        guard hotTimer == nil else { return }
        stillSince = Date()
        hotTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let before = self.lastFrame
                self.sync()
                if self.lastFrame != before { self.stillSince = Date() }
                else if Date().timeIntervalSince(self.stillSince) > 0.3 { self.hotTimer?.invalidate(); self.hotTimer = nil }
            }
        }
    }

    private func axFrame() -> CGRect? {
        guard let axWin else { return nil }
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWin, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(axWin, kAXSizeAttribute as CFString, &sv) == .success else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p); AXValueGetValue(sv as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }
    private func axBool(_ a: String) -> Bool {
        guard let axWin else { return false }
        var v: CFTypeRef?; AXUIElementCopyAttributeValue(axWin, a as CFString, &v); return (v as? Bool) ?? false
    }

    var isFullScreen: Bool { axBool("AXFullScreen") }
    var targetOnScreen: Bool {
        (CGWindowListCopyWindowInfo([.optionIncludingWindow], wid) as? [[String: Any]])?.first?[kCGWindowIsOnscreen as String] as? Bool ?? false
    }
    var overlayNumber: Int { window.windowNumber }
    var overlayVisible: Bool {
        (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber)) as? [[String: Any]])?.first?[kCGWindowIsOnscreen as String] as? Bool ?? false
    }

    /// Put the ring exactly around the target, directly BELOW it in z-order (target covers the middle).
    func sync() {
        guard state != .idle, let r = axFrame(), !axBool(kAXMinimizedAttribute), !isFullScreen, targetOnScreen else {
            window.orderOut(nil); bar.orderOut(nil); return
        }
        lastFrame = r
        let primaryH = NSScreen.screens.first?.frame.height ?? 0          // AX: top-left origin
        let cocoa = CGRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height)
            .insetBy(dx: -Look.pad, dy: -Look.pad)
        window.setFrame(cocoa, display: true)
        window.order(.below, relativeTo: Int(wid))
        let barRect = CGRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height)   // whole window
        if bar.frame.size != barRect.size { barState = nil }                                        // repaint on resize
        bar.setFrame(barRect, display: true)
        if barState != state { paintBar(state); barState = state }
        bar.order(.above, relativeTo: Int(wid))
        if !overlayVisible {
            // pinned to the Space it was first shown on; the target moved Spaces (M0 ④) ⇒ fresh window
            let s = state
            window.orderOut(nil); window.close()
            window = Glow.makeWindow(); view.apply(s)
            window.setFrame(cocoa, display: true)
            window.order(.below, relativeTo: Int(wid))
        }
    }
}

// MARK: - Screen-edge glow while a full-screen Space hides the other windows (Keng: ≈3pt, gold/red)

@MainActor
final class EdgeGlow {
    private var windows: [NSWindow] = []

    func show(_ s: WorkState, on screen: NSScreen) {
        hide()
        let w = GlowWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false; w.ignoresMouseEvents = true
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let v = NSView(frame: NSRect(origin: .zero, size: screen.frame.size)); v.wantsLayer = true
        let l = CAShapeLayer()
        l.path = CGPath(rect: v.bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        l.fillColor = nil; l.lineWidth = 3
        l.strokeColor = Look.color(s).withAlphaComponent(0.9).cgColor
        l.shadowColor = Look.color(s).cgColor; l.shadowRadius = 6; l.shadowOpacity = 1; l.shadowOffset = .zero
        v.layer?.addSublayer(l)
        w.contentView = v
        w.orderFrontRegardless()
        windows.append(w)
    }
    func hide() { windows.forEach { $0.orderOut(nil); $0.close() }; windows.removeAll() }
    var isShowing: Bool { !windows.isEmpty }
}
