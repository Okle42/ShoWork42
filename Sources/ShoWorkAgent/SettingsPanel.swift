import AppKit
import SwiftUI
import ShoWorkCore

/// Settings panel, styled after cool91's (Keng 09-26): borderless floating glass panel, never steals
/// focus unless you use a control, draggable anywhere, Esc / ✕ to close. Everything applies instantly.
/// Glass follows apple-design liquid-glass §3.1a (whole-window glass ⇒ .clear + tint; solid when
/// Reduce Transparency is on; no solid cards on the glass).
@MainActor
final class SettingsPanel: NSObject, NSWindowDelegate {
    static let shared = SettingsPanel()
    private var panel: NSPanel?
    static let width: CGFloat = 480

    func toggle() {
        if let p = panel, p.isVisible { p.orderOut(nil); return }
        show()
    }

    func show() {
        if panel == nil { build() }
        panel?.orderFrontRegardless()
        panel?.makeKey()
    }

    private func build() {
        let host = NSHostingView(rootView: SettingsView(close: { [weak self] in self?.panel?.orderOut(nil) }))
        host.sizingOptions = []                                    // the panel sizes itself (cool91: intrinsic size overflowed)
        let size = NSSize(width: Self.width, height: min(760, (NSScreen.main?.visibleFrame.height ?? 800) - 40))
        let p = KeyPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        p.title = "ShoWork42 設定"                                 // invisible, but VoiceOver uses it
        p.isMovableByWindowBackground = true
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.isFloatingPanel = true; p.becomesKeyOnlyIfNeeded = true; p.hidesOnDeactivate = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.delegate = self

        let radius: CGFloat = 26
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let bg: NSView
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let solid = NSView(); solid.wantsLayer = true
            solid.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            solid.layer?.cornerRadius = radius; solid.layer?.cornerCurve = .continuous
            bg = solid
        } else {
            // NSGlassEffectView did not render for this bare (non-.app) agent — the desktop showed through
            // sharp and unblurred (09-26, three tries). Use the behind-window blur + a dim layer, which is
            // cool91's macOS 14–25 path and renders everywhere.
            let fx = NSVisualEffectView(); fx.material = .hudWindow; fx.blendingMode = .behindWindow; fx.state = .active
            fx.maskImage = NSImage(size: NSSize(width: radius * 2 + 1, height: radius * 2 + 1), flipped: false) { r in
                NSColor.black.setFill(); NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill(); return true
            }.then { $0.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius); $0.resizingMode = .stretch }
            let dim = DimView(frame: fx.bounds); dim.radius = radius; dim.autoresizingMask = [.width, .height]
            fx.addSubview(dim)
            bg = fx
        }
        bg.frame = container.bounds; bg.autoresizingMask = [.width, .height]
        container.addSubview(bg)
        host.frame = bg.bounds; host.autoresizingMask = [.width, .height]
        host.translatesAutoresizingMaskIntoConstraints = true
        // cool91: content goes INSIDE the glass (its contentView), never as a sibling on top of it —
        // as a sibling the tint doesn't sit under the content and the panel reads see-through (09-26)
        bg.addSubview(host)
        p.contentView = container

        p.setFrameAutosaveName("showork.settings")
        if !p.setFrameUsingName("showork.settings"), let vf = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2))
        }
        panel = p
    }
}

/// cool91's glass: .clear + a STATIC tint picked from the current appearance (a dynamic NSColor was
/// not honoured by NSGlassEffectView — the panel came out see-through, 09-26), re-applied on change.
@available(macOS 26.0, *)
final class TintedGlass: NSGlassEffectView {
    func applyStyle() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        var a: CGFloat = dark ? 0.70 : 0.62
        if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast { a = dark ? 0.85 : 0.90 }
        style = .clear
        tintColor = dark ? NSColor(srgbRed: 0, green: 0, blue: 0.02, alpha: a) : NSColor(white: 1, alpha: a)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyStyle() }
}

/// dark/light scrim over the blur so text stays readable on any background (cool91 LegacyDimView values)
final class DimView: NSView {
    var radius: CGFloat = 26
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        var a: CGFloat = dark ? 0.55 : 0.60
        if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast { a = dark ? 0.8 : 0.85 }
        layer?.backgroundColor = (dark ? NSColor(srgbRed: 0, green: 0, blue: 0.02, alpha: a) : NSColor(white: 1, alpha: a)).cgColor
        layer?.cornerRadius = radius; layer?.cornerCurve = .continuous
    }
}

extension NSImage { func then(_ f: (NSImage) -> Void) -> NSImage { f(self); return self } }

/// borderless panels can't become key by default; controls and Esc need it
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }       // Esc closes
}

// MARK: - SwiftUI content

struct SettingsView: View {
    var close: () -> Void
    @ObservedObject private var glow = GlowSettings.shared
    @ObservedObject private var layout = LayoutSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("ShoWork42 設定").font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("關閉").accessibilityLabel("關閉")
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("光芒") {
                        Text("每一種狀態各自設定：要不要亮、顏色、外圍光芒的款式與速度。右邊是即時預覽。")
                            .font(.callout).foregroundStyle(.secondary)
                        ForEach([WorkState.working, .done, .input], id: \.self) { s in
                            StateRow(state: s)
                            if s != .input { Divider() }
                        }
                        HStack { Spacer(); Button("回復預設值") { glow.reset() }.controlSize(.small) }
                    }
                    section("排版") {
                        Toggle("視窗數量變動時自動排版", isOn: $layout.autoArrange)
                            .toggleStyle(.switch).controlSize(.mini)
                        HStack {
                            Text("4 個視窗時")
                            Spacer()
                            Picker("4 個視窗時", selection: $layout.fourStyle) {
                                Text("四等分直欄").tag(LayoutPlan.FourStyle.columns)
                                Text("上下左右 2×2").tag(LayoutPlan.FourStyle.grid)
                            }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                        }
                        HStack {
                            Text("立即排版").foregroundStyle(.secondary)
                            Text("⌃⌥L").font(.callout.monospaced()).foregroundStyle(.secondary)
                            Spacer()
                            Button("立即排版") { Arranger.shared.arrange() }
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
            }
        }
    }

    @ViewBuilder private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.semibold))
            content()
        }
    }
}

/// One state: switch, colour, style, speed + a live preview drawn by the real GlowView.
struct StateRow: View {
    let state: WorkState
    @ObservedObject private var glow = GlowSettings.shared

    private var name: String { switch state { case .working: "工作中"; case .done: "已完成"; case .input: "等你回答"; case .idle: "" } }
    private var hint: String {
        switch state {
        case .working: "AI 正在處理"
        case .done: "做完了，等你來看（點進視窗、按鍵或點擊就消失）"
        case .input: "AI 卡住在等你回覆或允許權限"
        case .idle: ""
        }
    }
    private var binding: Binding<StateLook> {
        Binding(get: { glow.look(state) }, set: { glow.looks[state] = $0 })
    }
    private var color: Binding<Color> {
        Binding(get: { Color(nsColor: glow.look(state).color) },
                set: { var l = glow.look(state); l.hex = StateLook.hex(NSColor($0)); glow.looks[state] = l })
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle().fill(Color(nsColor: glow.look(state).color)).frame(width: 10, height: 10)
                        .accessibilityHidden(true)
                    Text(name).font(.headline)
                    Spacer()
                    Toggle(name, isOn: binding.enabled).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                }
                Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Group {
                    LabeledContent("顏色") { ColorPicker("顏色", selection: color, supportsOpacity: false).labelsHidden() }
                    LabeledContent("款式") {
                        Picker("款式", selection: binding.style) {
                            ForEach(GlowStyle.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    LabeledContent("速度") {
                        HStack(spacing: 6) {
                            Text("慢").font(.caption).foregroundStyle(.secondary)
                            Slider(value: binding.speed, in: 0.4...2.5).frame(width: 110).accessibilityLabel("\(name)的速度")
                            Text("快").font(.caption).foregroundStyle(.secondary)
                            Text(String(format: "%.1f×", glow.look(state).speed)).font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                        }
                    }
                }
                .disabled(!glow.look(state).enabled)
            }
            GlowPreview(state: state, look: glow.look(state))
                .frame(width: 150, height: 104)
                .opacity(glow.look(state).enabled ? 1 : 0.35)
                .accessibilityLabel("\(name)光芒預覽")
        }
        .padding(.vertical, 4)
    }
}

/// A mock terminal window with the REAL GlowView behind it — what you see is what the windows get.
struct GlowPreview: NSViewRepresentable {
    let state: WorkState
    let look: StateLook

    func makeNSView(context: Context) -> PreviewHost { PreviewHost() }
    func updateNSView(_ v: PreviewHost, context: Context) { v.show(state) }

    final class PreviewHost: NSView {
        private let glow = GlowView(frame: .zero)
        private let win = NSView()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            addSubview(glow)
            win.wantsLayer = true
            win.layer?.backgroundColor = NSColor(srgbRed: 0.12, green: 0.14, blue: 0.18, alpha: 1).cgColor
            win.layer?.cornerRadius = Look.corner; win.layer?.cornerCurve = .continuous
            addSubview(win)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            let w = bounds.insetBy(dx: 26, dy: 24)
            win.frame = w
            glow.frame = w.insetBy(dx: -(Look.pad - 1), dy: -(Look.pad - 1))
        }
        @MainActor func show(_ s: WorkState) { glow.apply(s, force: true) }
    }
}

/// Layout settings, shared with Arranger (same UserDefaults keys)
@MainActor
final class LayoutSettings: ObservableObject {
    static let shared = LayoutSettings()
    @Published var autoArrange: Bool { didSet { Arranger.shared.autoArrange = autoArrange } }
    @Published var fourStyle: LayoutPlan.FourStyle { didSet { if Arranger.shared.fourStyle != fourStyle { Arranger.shared.fourStyle = fourStyle; Arranger.shared.arrange() } } }
    private init() {
        autoArrange = Arranger.shared.autoArrange
        fourStyle = Arranger.shared.fourStyle
    }
}
