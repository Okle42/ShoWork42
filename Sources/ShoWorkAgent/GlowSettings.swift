import AppKit
import ShoWorkCore

/// Outer-glow styles from the 09-26 decision board (docs/decisions/glow_style_board.html).
enum GlowStyle: String, CaseIterable, Codable, Identifiable {
    case breathe, orbit, ripple, drift, sparkle, aurora
    var id: String { rawValue }
    var title: String {
        switch self {
        case .breathe: "呼吸"
        case .orbit: "流光繞行"
        case .ripple: "漣漪外擴"
        case .drift: "光霧飄動"
        case .sparkle: "微光粒子"
        case .aurora: "極光旋轉"
        }
    }
}

/// How one state (working / done / input) looks. Keng 09-26: every state is tuned on its own —
/// on/off, colour, style, speed.
struct StateLook: Codable, Equatable {
    var enabled: Bool
    var hex: String
    var style: GlowStyle
    /// 0.4…2.5, 1 = normal; higher = faster (Keng 09-26: 光的快慢要可以調)
    var speed: Double
    /// animation durations are multiplied by this
    var period: Double { 1 / max(0.4, min(speed, 2.5)) }

    var color: NSColor {
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0xFFFFFF
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    static func hex(_ c: NSColor) -> String {
        let s = c.usingColorSpace(.sRGB) ?? c
        return String(format: "#%02X%02X%02X", Int(round(s.redComponent * 255)), Int(round(s.greenComponent * 255)), Int(round(s.blueComponent * 255)))
    }
}

@MainActor
final class GlowSettings: ObservableObject {
    static let shared = GlowSettings()
    static let changed = Notification.Name("sw42.glowSettingsChanged")
    static let defaults: [WorkState: StateLook] = [
        .working: StateLook(enabled: true, hex: "#9E66FF", style: .breathe, speed: 1),
        .done:    StateLook(enabled: true, hex: "#FFC23D", style: .breathe, speed: 1),
        .input:   StateLook(enabled: true, hex: "#FF4040", style: .breathe, speed: 1),
    ]
    private let store = UserDefaults(suiteName: "ai.okle42.showork") ?? .standard

    @Published var looks: [WorkState: StateLook] {
        didSet {
            if let d = try? JSONEncoder().encode(looks.map { [$0.key.rawValue: $0.value] }) { store.set(d, forKey: "glowLooks.v2") }
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    private init() {
        var l = Self.defaults
        if let d = store.data(forKey: "glowLooks.v2"), let saved = try? JSONDecoder().decode([[String: StateLook]].self, from: d) {
            for m in saved { for (k, v) in m { if let s = WorkState(rawValue: k) { l[s] = v } } }
        }
        looks = l
    }

    func look(_ s: WorkState) -> StateLook { looks[s] ?? Self.defaults[s] ?? Self.defaults[.working]! }
    func reset() { looks = Self.defaults }
}
