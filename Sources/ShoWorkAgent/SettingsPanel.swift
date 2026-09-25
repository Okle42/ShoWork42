import AppKit
import SwiftUI
import ShoWorkCore

// Settings window, same structure as cool91's (Keng 09-26: 「像這樣做成分頁」):
// NSTabViewController with .toolbar tabs (the System-Settings-style icon row) + one SwiftUI grouped Form
// per page. The title follows the tab, the last tab is remembered, no resize/minimize (HIG Settings),
// everything applies the moment you change it.

enum SettingsTab: String, CaseIterable {
    case working, done, input, layout, about
    var title: String {
        switch self {
        case .working: "工作中"
        case .done: "已完成"
        case .input: "等你回答"
        case .layout: "排版"
        case .about: "關於與檢查"
        }
    }
    var symbol: String {
        switch self {
        case .working: "sparkles"
        case .done: "checkmark.circle"
        case .input: "exclamationmark.bubble"
        case .layout: "rectangle.3.group"
        case .about: "stethoscope"
        }
    }
    var state: WorkState? {
        switch self { case .working: .working; case .done: .done; case .input: .input; default: nil }
    }
    static let key = "settings.tab"
    static var last: SettingsTab {
        (UserDefaults(suiteName: "ai.okle42.showork")?.string(forKey: key)).flatMap(SettingsTab.init(rawValue:)) ?? .working
    }
}

final class SettingsTabController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard let id = tabViewItem?.identifier as? String, let t = SettingsTab(rawValue: id) else { return }
        view.window?.title = t.title
        UserDefaults(suiteName: "ai.okle42.showork")?.set(id, forKey: SettingsTab.key)
    }
}

@MainActor
final class SettingsPanel: NSObject, NSWindowDelegate {
    static let shared = SettingsPanel()
    private var window: NSWindow?
    private var tabs: SettingsTabController?

    func toggle() { if window?.isVisible == true { window?.orderOut(nil) } else { show() } }

    func show(tab: SettingsTab? = nil) {
        let w = window ?? build()
        let t = tab ?? SettingsTab.last
        if let i = SettingsTab.allCases.firstIndex(of: t) { tabs?.selectedTabViewItemIndex = i }
        w.title = t.title
        NSApp.activate(ignoringOtherApps: true)        // accessory app: otherwise it opens behind other apps
        w.makeKeyAndOrderFront(nil)
    }

    private func build() -> NSWindow {
        let tc = SettingsTabController()
        tc.tabStyle = .toolbar
        tc.transitionOptions = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? [] : [.crossfade, .allowUserInteraction]
        for t in SettingsTab.allCases {
            let host = NSHostingController(rootView: SettingsPage(tab: t))
            host.sizingOptions = [.preferredContentSize]
            host.title = t.title
            let item = NSTabViewItem(viewController: host)
            item.identifier = t.rawValue
            item.label = t.title
            item.image = NSImage(systemSymbolName: t.symbol, accessibilityDescription: t.title)
            tc.addTabViewItem(item)
        }
        let w = NSWindow(contentViewController: tc)
        w.styleMask = [.titled, .closable]
        w.toolbarStyle = .preference
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setFrameAutosaveName("showork.settingsWindow")
        if !w.setFrameUsingName("showork.settingsWindow") { w.center() }
        tabs = tc
        window = w
        return w
    }
}

// MARK: - pages

struct SettingsPage: View {
    let tab: SettingsTab
    var body: some View {
        Group {
            if let s = tab.state { StatePage(state: s) }
            else if tab == .layout { LayoutPage() }
            else { AboutPage() }
        }
        .frame(width: 560)
    }
}

/// One state: on/off, colour, style, speed, brightness, width + a big live preview (the real GlowView).
struct StatePage: View {
    let state: WorkState
    @ObservedObject private var glow = GlowSettings.shared

    private var hint: String {
        switch state {
        case .working: "AI 正在處理時，視窗外圍的光。"
        case .done: "AI 做完了、等你來看時的光。點進那個視窗、在裡面按鍵或點擊就會消失。"
        case .input: "AI 卡住在等你回覆或允許權限時的光。要等 AI 繼續才會消失。"
        case .idle: ""
        }
    }
    private var look: Binding<StateLook> { Binding(get: { glow.look(state) }, set: { glow.looks[state] = $0 }) }
    private var color: Binding<Color> {
        Binding(get: { Color(nsColor: glow.look(state).color) },
                set: { var l = glow.look(state); l.hex = StateLook.hex(NSColor($0)); glow.looks[state] = l })
    }

    var body: some View {
        Form {
            Section {
                GlowPreview(state: state, look: glow.look(state))
                    .frame(maxWidth: .infinity).frame(height: 190)
                    .opacity(glow.look(state).enabled ? 1 : 0.3)
                    .accessibilityLabel("光芒預覽")
            } footer: { Text(hint).foregroundStyle(.secondary) }

            Section {
                Toggle("顯示這個狀態的光", isOn: look.enabled).toggleStyle(.switch).controlSize(.mini)
            }
            Section("外觀") {
                ColorPicker("顏色", selection: color, supportsOpacity: false)
                Picker("款式", selection: look.style) { ForEach(GlowStyle.allCases) { Text($0.title).tag($0) } }
                slider("亮度", look.brightness, 0.3...1.6, low: "淡", high: "亮")
                slider("寬度", look.width, 0.5...2, low: "窄", high: "寬")
                slider("速度", look.speed, 0.4...2.5, low: "慢", high: "快")
            }
            .disabled(!glow.look(state).enabled)
            Section {
                HStack { Spacer(); Button("回復這一頁的預設值") { glow.looks[state] = GlowSettings.defaults[state] } }
            }
        }
        .formStyle(.grouped)
        .frame(height: 620)
    }

    private func slider(_ title: String, _ v: Binding<Double>, _ r: ClosedRange<Double>, low: String, high: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text(low).font(.caption).foregroundStyle(.secondary)
                Slider(value: v, in: r).frame(width: 200).accessibilityLabel(title)
                Text(high).font(.caption).foregroundStyle(.secondary)
                Text(String(format: "%.1f×", v.wrappedValue)).font(.body.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }
}

struct LayoutPage: View {
    @ObservedObject private var layout = LayoutSettings.shared
    var body: some View {
        Form {
            Section {
                Toggle("視窗數量變動時自動排版", isOn: $layout.autoArrange).toggleStyle(.switch).controlSize(.mini)
            } footer: { Text("開或關一個終端機視窗時，自動把所有終端機視窗重新排好。").foregroundStyle(.secondary) }
            Section {
                Picker("4 個視窗時", selection: $layout.fourStyle) {
                    Text("四等分直欄").tag(LayoutPlan.FourStyle.columns)
                    Text("上下左右 2×2").tag(LayoutPlan.FourStyle.grid)
                }
                .pickerStyle(.segmented)
            }
            Section {
                LabeledContent("立即排版") {
                    HStack {
                        Text("⌃⌥L").font(.body.monospaced()).foregroundStyle(.secondary)
                        Button("立即排版") { Arranger.shared.arrange() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 300)
    }
}

struct AboutPage: View {
    private var trusted: Bool { AXIsProcessTrusted() }
    private var logURL: URL { Paths.supportDir.appendingPathComponent("agent.log") }
    var body: some View {
        Form {
            Section {
                LabeledContent("ShoWork42", value: "開發版（本機）")
                LabeledContent("輔助使用權限") {
                    Label(trusted ? "已允許" : "尚未允許", systemImage: trusted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(trusted ? .green : .red)
                }
            }
            Section {
                LabeledContent("紀錄檔") {
                    Button("在 Finder 中顯示") { NSWorkspace.shared.activateFileViewerSelecting([logURL]) }
                }
            } footer: { Text("光暈亮起、清除的原因都記在這裡，回報問題時很有用。").foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
        .frame(height: 280)
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
            layer?.backgroundColor = NSColor(srgbRed: 0.05, green: 0.06, blue: 0.09, alpha: 1).cgColor
            layer?.cornerRadius = 8
            layer?.masksToBounds = true
            addSubview(glow)
            win.wantsLayer = true
            win.layer?.backgroundColor = NSColor(srgbRed: 0.12, green: 0.14, blue: 0.18, alpha: 1).cgColor
            win.layer?.cornerRadius = Look.corner; win.layer?.cornerCurve = .continuous
            addSubview(win)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            let w = CGRect(x: bounds.midX - 110, y: bounds.midY - 55, width: 220, height: 110)
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
    @Published var fourStyle: LayoutPlan.FourStyle {
        didSet { if Arranger.shared.fourStyle != fourStyle { Arranger.shared.fourStyle = fourStyle; Arranger.shared.arrange() } }
    }
    private init() {
        autoArrange = Arranger.shared.autoArrange
        fourStyle = Arranger.shared.fourStyle
    }
}
