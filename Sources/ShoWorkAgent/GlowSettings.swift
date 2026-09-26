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
    /// 0.3…1.6, 1 = default — how strong the light is (inner ring and outer glow)
    var brightness: Double = 1
    /// 0.5…2, 1 = default — how far the outer glow spreads
    var width: Double = 1

    var b: CGFloat { CGFloat(max(0.3, min(brightness, 1.6))) }
    var w: CGFloat { CGFloat(max(0.5, min(width, 2))) }

    init(enabled: Bool, hex: String, style: GlowStyle, speed: Double, brightness: Double = 1, width: Double = 1) {
        self.enabled = enabled; self.hex = hex; self.style = style; self.speed = speed
        self.brightness = brightness; self.width = width
    }
    // older saves have no brightness/width — keep the user's colour/style/speed and default the rest
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        hex = try c.decode(String.self, forKey: .hex)
        style = try c.decode(GlowStyle.self, forKey: .style)
        speed = try c.decode(Double.self, forKey: .speed)
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? 1
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 1
    }

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
        .done:    StateLook(enabled: true, hex: "#30D158", style: .breathe, speed: 1),   // Keng 09-26：完成由金改綠
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
        // Keng 09-26: done changed from gold to green. Saves that still carry the old default gold get the new
        // green once; every other tweak (speed, style, brightness, width) is kept. A colour the user picked stays.
        if !store.bool(forKey: Self.doneGreenMigrated) {
            if var d = l[.done], d.hex.uppercased() == Self.oldDoneGold {
                d.hex = Self.defaults[.done]!.hex
                l[.done] = d
                if let data = try? JSONEncoder().encode(l.map { [$0.key.rawValue: $0.value] }) { store.set(data, forKey: "glowLooks.v2") }
            }
            store.set(true, forKey: Self.doneGreenMigrated)
        }
        looks = l
    }
    private static let oldDoneGold = "#FFC23D"
    private static let doneGreenMigrated = "migrated.doneGreen"

    func look(_ s: WorkState) -> StateLook { looks[s] ?? Self.defaults[s] ?? Self.defaults[.working]! }
    func reset() { looks = Self.defaults }
}
