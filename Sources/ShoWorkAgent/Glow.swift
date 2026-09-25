import AppKit
import QuartzCore
import ShoWorkCore

// MARK: - Look — colours and styles come from GlowSettings (the settings panel)

enum Look {
    static let pad: CGFloat = 64            // room for the glow to fade out completely (no hard edge at the overlay border)
    static let spread: CGFloat = 12
    static let corner: CGFloat = 12

    @MainActor static func color(_ s: WorkState) -> NSColor {
        s == .idle ? .clear : GlowSettings.shared.look(s).color
    }
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// The outer glow around a window. A crisp edge ring is always there; the "floating" part is one of
/// six styles (decision board 09-26), each state configured on its own in the settings panel.
/// Reduce Motion ⇒ every style falls back to a still soft glow.
@MainActor
final class GlowView: NSView {
    private let edge = CAShapeLayer()
    private let fx = CALayer()                       // style layers live here; rebuilt on change
    private(set) var state: WorkState = .idle
    private var look: StateLook?
    private var builtSize: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(fx)
        layer?.addSublayer(edge)
        edge.fillColor = nil; edge.shadowOffset = .zero
        edge.lineWidth = 2.5; edge.shadowRadius = 5; edge.shadowOpacity = 1
    }
    required init?(coder: NSCoder) { fatalError() }

    /// the window outline inside this view
    private var outline: CGRect { bounds.insetBy(dx: Look.pad - 1, dy: Look.pad - 1) }
    private func outlinePath(_ r: CGRect? = nil) -> CGPath {
        CGPath(roundedRect: r ?? outline, cornerWidth: Look.corner, cornerHeight: Look.corner, transform: nil)
    }

    override func layout() {
        super.layout()
        edge.frame = bounds; edge.path = outlinePath()
        fx.frame = bounds
        if bounds.size != builtSize { rebuild() }
    }

    func apply(_ s: WorkState, force: Bool = false) {
        let l = s == .idle ? nil : GlowSettings.shared.look(s)
        guard force || s != state || l != look else { return }
        state = s; look = l
        rebuild()
    }

    private func rebuild() {
        builtSize = bounds.size
        fx.sublayers?.forEach { $0.removeFromSuperlayer() }
        fx.mask = nil
        edge.removeAllAnimations()
        guard let look, state != .idle, bounds.width > 2 * Look.pad else { edge.strokeColor = nil; edge.shadowColor = nil; return }
        let c = look.color
        edge.strokeColor = c.withAlphaComponent(0.95).cgColor; edge.shadowColor = c.cgColor
        let still = Look.reduceMotion
        let k = look.period
        switch still ? .breathe : look.style {
        case .breathe: breathe(c, k: k, still: still)
        case .orbit:   orbit(c, k: k)
        case .ripple:  ripple(c, k: k)
        case .drift:   drift(c, k: k)
        case .sparkle: sparkle(c, k: k)
        case .aurora:  aurora(c, k: k)
        }
    }

    // A. 呼吸 — width + brightness rise and fall together
    private func breathe(_ c: NSColor, k: Double, still: Bool) {
        let halo = CAShapeLayer()
        halo.frame = bounds; halo.path = outlinePath(); halo.fillColor = nil
        halo.strokeColor = c.withAlphaComponent(0.35).cgColor; halo.lineWidth = 6
        halo.shadowColor = c.cgColor; halo.shadowOpacity = 1; halo.shadowOffset = .zero; halo.shadowRadius = Look.spread
        fx.addSublayer(halo)
        guard !still else { return }
        let g = CAAnimationGroup()
        // Keng 09-26: "太延伸、末端有一層" — keep the widest breath (radius 20 ⇒ visible ~2×20pt) well inside
        // the 64pt pad so it fades to nothing instead of being cut at the overlay's edge
        let radius = CABasicAnimation(keyPath: "shadowRadius"); radius.fromValue = Look.spread * 0.75; radius.toValue = Look.spread * 1.65
        let bright = CABasicAnimation(keyPath: "shadowOpacity"); bright.fromValue = 0.55; bright.toValue = 0.95
        let width = CABasicAnimation(keyPath: "lineWidth"); width.fromValue = 4; width.toValue = 8
        g.animations = [radius, bright, width]
        g.duration = 1.6 * k; g.autoreverses = true; g.repeatCount = .infinity
        g.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        halo.add(g, forKey: "style")
    }

    /// soft-edged ring around the window (image mask), for the gradient styles
    private func featherMask(inner: CGFloat, outer: CGFloat) -> CALayer {
        let size = bounds.size
        let img = NSImage(size: size, flipped: false) { _ in
            let ctx = NSGraphicsContext.current!.cgContext
            let steps = 14
            for i in 0..<steps {                                // concentric strokes, alpha fading outward
                let t = CGFloat(i) / CGFloat(steps - 1)
                let inset = Look.pad - 1 - inner - t * (outer - inner)
                let r = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
                ctx.setStrokeColor(NSColor(white: 1, alpha: (1 - t) * 0.35).cgColor)
                ctx.setLineWidth((outer - inner) / CGFloat(steps) * 2.2)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: Look.corner + inner + t * (outer - inner),
                                   cornerHeight: Look.corner + inner + t * (outer - inner), transform: nil))
                ctx.strokePath()
            }
            return true
        }
        let m = CALayer(); m.frame = bounds; m.contents = img
        return m
    }

    private func spinningConic(_ colors: [NSColor], stops: [NSNumber], period: Double) -> CALayer {
        let side = hypot(bounds.width, bounds.height)
        let g = CAGradientLayer()
        g.type = .conic
        g.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        g.startPoint = CGPoint(x: 0.5, y: 0.5); g.endPoint = CGPoint(x: 0.5, y: 0)
        g.colors = colors.map(\.cgColor); g.locations = stops
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0; spin.toValue = -2 * Double.pi; spin.duration = period; spin.repeatCount = .infinity
        g.add(spin, forKey: "style")
        return g
    }

    // B. 流光繞行 — a bright arc runs around the frame
    private func orbit(_ c: NSColor, k: Double) {
        let base = CAShapeLayer()
        base.frame = bounds; base.path = outlinePath(); base.fillColor = nil; base.strokeColor = c.withAlphaComponent(0.25).cgColor
        base.lineWidth = 6; base.shadowColor = c.cgColor; base.shadowOpacity = 0.7; base.shadowOffset = .zero; base.shadowRadius = 10
        fx.addSublayer(base)
        let holder = CALayer(); holder.frame = bounds
        holder.addSublayer(spinningConic([.clear, .clear, c.withAlphaComponent(0.6), c, .white.withAlphaComponent(0.9), .clear],
                                         stops: [0, 0.62, 0.8, 0.9, 0.93, 1], period: 3.4 * k))
        holder.mask = featherMask(inner: -2, outer: 30)
        fx.addSublayer(holder)
    }

    // C. 漣漪外擴 — rings leave the frame and fade
    private func ripple(_ c: NSColor, k: Double) {
        let base = CAShapeLayer()
        base.frame = bounds; base.path = outlinePath(); base.fillColor = nil; base.strokeColor = c.withAlphaComponent(0.4).cgColor
        base.lineWidth = 6; base.shadowColor = c.cgColor; base.shadowOpacity = 0.9; base.shadowOffset = .zero; base.shadowRadius = 12
        fx.addSublayer(base)
        let d = 3.0 * k
        for i in 0..<3 {
            let r = CAShapeLayer()
            r.frame = bounds; r.path = outlinePath(); r.fillColor = nil
            r.strokeColor = c.cgColor; r.lineWidth = 2; r.opacity = 0
            r.shadowColor = c.cgColor; r.shadowOpacity = 1; r.shadowOffset = .zero; r.shadowRadius = 4
            let grow = CABasicAnimation(keyPath: "path")
            grow.fromValue = outlinePath(); grow.toValue = outlinePath(outline.insetBy(dx: -(Look.pad - 6), dy: -(Look.pad - 6)))
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0.9; fade.toValue = 0
            let g = CAAnimationGroup(); g.animations = [grow, fade]; g.duration = d; g.repeatCount = .infinity
            g.timingFunction = CAMediaTimingFunction(name: .easeOut)
            g.beginTime = CACurrentMediaTime() + Double(i) * d / 3
            r.add(g, forKey: "style")
            fx.addSublayer(r)
        }
    }

    // D. 光霧飄動 — soft blobs drift around the window
    private func drift(_ c: NSColor, k: Double) {
        let o = outline
        let spots = [CGPoint(x: o.minX + o.width * 0.2, y: o.maxY), CGPoint(x: o.maxX, y: o.minY + o.height * 0.65),
                     CGPoint(x: o.minX + o.width * 0.7, y: o.minY), CGPoint(x: o.minX, y: o.minY + o.height * 0.3)]
        let light = c.blended(withFraction: 0.35, of: .white) ?? c
        for (i, p) in spots.enumerated() {
            let b = CALayer()
            let w = min(o.width, o.height) * 0.55
            b.frame = CGRect(x: p.x - w / 2, y: p.y - w * 0.3, width: w, height: w * 0.6)
            b.shadowPath = CGPath(ellipseIn: CGRect(origin: .zero, size: b.frame.size), transform: nil)
            b.shadowColor = (i % 2 == 0 ? c : light).cgColor; b.shadowOpacity = 0.75; b.shadowRadius = 26; b.shadowOffset = .zero
            let m = CABasicAnimation(keyPath: "position")
            m.fromValue = b.position
            m.toValue = CGPoint(x: b.position.x + CGFloat([22, -18, 16, -20][i]), y: b.position.y + CGFloat([-12, 14, 10, -14][i]))
            m.duration = [7.0, 9.0, 8.0, 6.0][i] * k; m.autoreverses = true; m.repeatCount = .infinity
            m.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            b.add(m, forKey: "style")
            fx.addSublayer(b)
        }
    }

    // E. 微光粒子 — sparks float off the frame and fade
    private func sparkle(_ c: NSColor, k: Double) {
        let base = CAShapeLayer()
        base.frame = bounds; base.path = outlinePath(); base.fillColor = nil; base.strokeColor = c.withAlphaComponent(0.35).cgColor
        base.lineWidth = 5; base.shadowColor = c.cgColor; base.shadowOpacity = 0.8; base.shadowOffset = .zero; base.shadowRadius = 10
        fx.addSublayer(base)
        let e = CAEmitterLayer()
        e.frame = bounds
        e.emitterPosition = CGPoint(x: bounds.midX, y: bounds.midY)
        e.emitterSize = outline.size
        e.emitterShape = .rectangle; e.emitterMode = .outline
        let dot = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { r in
            NSColor.white.setFill(); NSBezierPath(ovalIn: r).fill(); return true
        }
        let cell = CAEmitterCell()
        cell.contents = dot.cgImage(forProposedRect: nil, context: nil, hints: nil)
        cell.color = (c.blended(withFraction: 0.3, of: .white) ?? c).cgColor
        cell.birthRate = Float(10 / k); cell.lifetime = Float(2.6 * k)
        cell.velocity = 14; cell.velocityRange = 8; cell.emissionRange = .pi * 2
        cell.scale = 0.45; cell.scaleRange = 0.25; cell.alphaSpeed = -Float(0.38 / k)
        e.emitterCells = [cell]
        e.shadowColor = c.cgColor; e.shadowOpacity = 1; e.shadowRadius = 4; e.shadowOffset = .zero
        fx.addSublayer(e)
    }

    // F. 極光旋轉 — light and deep bands of the colour turn slowly
    private func aurora(_ c: NSColor, k: Double) {
        let light = c.blended(withFraction: 0.45, of: .white) ?? c
        let deep = c.blended(withFraction: 0.35, of: .black) ?? c
        let holder = CALayer(); holder.frame = bounds
        holder.addSublayer(spinningConic([c, light, deep, c, light, deep, c],
                                         stops: [0, 0.17, 0.33, 0.5, 0.67, 0.83, 1], period: 9 * k))
        holder.mask = featherMask(inner: -2, outer: 34)
        fx.addSublayer(holder)
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
    /// settings changed: repaint with the new colour/style
    func restyle() { view.apply(state, force: true); barState = nil; sync() }
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
        guard !Look.reduceMotion else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.autoreverses = true; a.repeatCount = .infinity
        a.fromValue = 1.0; a.toValue = 0.6; a.duration = 1.6 * GlowSettings.shared.look(s).period
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
