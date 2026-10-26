import Foundation

// 太陽位置（10-21：3D 科技大樓的日出日落）。NOAA Solar Calculator 的公式（https://gml.noaa.gov/grad/solcalc/calcdetails.html），
// 純函式、本機算、不連網。預設地點台北（北緯 25.03、東經 121.56）。精度：日出日落 ±1 分鐘級，夠畫面用。

public struct SunSample: Equatable, Sendable {
    /// 太陽仰角（度，含大氣折射；地平線 0、負的在地平線下）
    public var elevation: Double
    /// 方位角（度，北 0、東 90、南 180、西 270）
    public var azimuth: Double
    /// 上午（太陽還在往上爬）：清晨與傍晚的配色不同
    public var rising: Bool
    public init(elevation: Double, azimuth: Double, rising: Bool) { self.elevation = elevation; self.azimuth = azimuth; self.rising = rising }
}

public enum Solar {
    public static let taipei = (lat: 25.03, lon: 121.56)

    @inline(__always) static func rad(_ d: Double) -> Double { d * .pi / 180 }
    @inline(__always) static func deg(_ r: Double) -> Double { r * 180 / .pi }

    /// 某個瞬間的赤緯（度）與均時差（分鐘）
    static func declinationAndEqTime(_ date: Date) -> (decl: Double, eqTime: Double) {
        let jd = date.timeIntervalSince1970 / 86400 + 2440587.5
        let jc = (jd - 2451545) / 36525
        let l0 = (280.46646 + jc * (36000.76983 + jc * 0.0003032)).truncatingRemainder(dividingBy: 360)
        let m = 357.52911 + jc * (35999.05029 - 0.0001537 * jc)
        let e = 0.016708634 - jc * (0.000042037 + 0.0000001267 * jc)
        let c = sin(rad(m)) * (1.914602 - jc * (0.004817 + 0.000014 * jc)) + sin(rad(2 * m)) * (0.019993 - 0.000101 * jc)
            + sin(rad(3 * m)) * 0.000289
        let trueLong = l0 + c
        let omega = 125.04 - 1934.136 * jc
        let appLong = trueLong - 0.00569 - 0.00478 * sin(rad(omega))
        let meanObliq = 23 + (26 + (21.448 - jc * (46.815 + jc * (0.00059 - jc * 0.001813))) / 60) / 60
        let obliq = meanObliq + 0.00256 * cos(rad(omega))
        let decl = deg(asin(sin(rad(obliq)) * sin(rad(appLong))))
        let y = pow(tan(rad(obliq / 2)), 2)
        let eq = 4 * deg(y * sin(2 * rad(l0)) - 2 * e * sin(rad(m)) + 4 * e * y * sin(rad(m)) * cos(2 * rad(l0))
                         - 0.5 * y * y * sin(4 * rad(l0)) - 1.25 * e * e * sin(2 * rad(m)))
        return (decl, eq)
    }

    /// 太陽仰角＋方位角（NOAA，含大氣折射修正）
    public static func position(at date: Date, lat: Double = taipei.lat, lon: Double = taipei.lon) -> SunSample {
        let (decl, eqTime) = declinationAndEqTime(date)
        let utcMin = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86400) / 60
        var tst = (utcMin + eqTime + 4 * lon).truncatingRemainder(dividingBy: 1440)
        if tst < 0 { tst += 1440 }
        let ha = tst / 4 < 0 ? tst / 4 + 180 : tst / 4 - 180          // 時角（度）：正午 0、下午正
        let cz = sin(rad(lat)) * sin(rad(decl)) + cos(rad(lat)) * cos(rad(decl)) * cos(rad(ha))
        let zenith = deg(acos(min(1, max(-1, cz))))
        let el = 90 - zenith
        // 大氣折射（NOAA 近似式）
        let refr: Double
        if el > 85 { refr = 0 }
        else {
            let te = tan(rad(el))
            if el > 5 { refr = 58.1 / te - 0.07 / pow(te, 3) + 0.000086 / pow(te, 5) }
            else if el > -0.575 { refr = 1735 + el * (-518.2 + el * (103.4 + el * (-12.79 + el * 0.711))) }
            else { refr = -20.772 / te }
        }
        let azDen = cos(rad(lat)) * sin(rad(zenith))
        var az: Double
        if abs(azDen) < 1e-9 { az = lat > 0 ? 180 : 0 }
        else {
            let a = (sin(rad(lat)) * cos(rad(zenith)) - sin(rad(decl))) / azDen
            let b = deg(acos(min(1, max(-1, a))))
            az = ha > 0 ? (b + 180).truncatingRemainder(dividingBy: 360) : (540 - b).truncatingRemainder(dividingBy: 360)
        }
        return SunSample(elevation: el + refr / 3600, azimuth: az, rising: ha < 0)
    }

    /// 這一天（calendar 的時區）的日出、日落時間（太陽上緣碰地平線，天頂角 90.833°）；極區沒有日出日落回 nil
    public static func sunTimes(on date: Date, calendar: Calendar = .current, lat: Double = taipei.lat, lon: Double = taipei.lon)
        -> (sunrise: Date, sunset: Date, noon: Date)? {
        let localNoon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
        // 當地正午那一刻的 UTC 日期（午夜）；事件時間＝這個午夜＋UTC 分鐘（可以是負的＝前一個 UTC 日）
        let day = floor(localNoon.timeIntervalSince1970 / 86400) * 86400
        func solve(_ guess: Date, sign: Double) -> Date? {
            var t = guess
            for _ in 0..<3 {         // 用上一次的時間重算赤緯與均時差（收斂到秒級）
                let (decl, eq) = declinationAndEqTime(t)
                let cosH = cos(rad(90.833)) / (cos(rad(lat)) * cos(rad(decl))) - tan(rad(lat)) * tan(rad(decl))
                guard sign == 0 || abs(cosH) <= 1 else { return nil }
                let h = sign == 0 ? 0 : deg(acos(cosH))
                let utcMin = 720 - 4 * (lon + sign * h) - eq
                t = Date(timeIntervalSince1970: day + utcMin * 60)
            }
            return t
        }
        guard let noon = solve(localNoon, sign: 0), let rise = solve(noon, sign: 1), let set = solve(noon, sign: -1) else { return nil }
        return (rise, set, noon)
    }
}

// MARK: - 天色（依太陽仰角連續混合）

/// 一個時間點的天色與燈光參數（顏色是 sRGB 0–1）。夜晚端、白天端跟改版前的二分燈光完全一樣（規範 §3.8／§3.8.1）
public struct SkyLook: Equatable, Sendable {
    public typealias RGB = SIMD3<Double>
    public var horizon: RGB, zenith: RGB
    /// 太陽那一側地平線的光暈（日出日落）：顏色與強度 0–1
    public var glow: RGB, glowAmount: Double
    public var ground: RGB
    /// 主光（白天＝太陽，夜晚＝月光，同一盞）
    public var keyColor: RGB, keyIntensity: Double
    public var ambientColor: RGB, ambientIntensity: Double
    /// 室內暖補光、夜晚戶外月光補光
    public var fill: Double, moonFill: Double
    /// 暗度：日夜兩套底色、門牌乘色、vignetting 依這個混合（0＝白天、1＝夜晚）
    public var dark: Double
    /// 燈：窗光、路燈、城市燈光、吊燈 omni、bloom（黃昏逐漸點亮、清晨逐漸熄滅）
    public var lamps: Double
    /// 主光方向：nil＝美術固定角度（白天固定、夜晚月光）；有值＝真實太陽（仰角已夾在 ≥3°，方位角北 0 順時針）
    public var sunDir: SunDir?
    public struct SunDir: Equatable, Sendable { public var elevation: Double; public var azimuth: Double }
    /// 雲量造成的「沒有直射陽光」0–1（10-21 天氣，Weather.swift）：靜態假影子依這個淡掉；晴天 0
    public var overcast: Double = 0

    public static func hex(_ h: UInt32) -> RGB { RGB(Double(h >> 16 & 255), Double(h >> 8 & 255), Double(h & 255)) / 255 }

    /// 改版前的白天（OfficeBuilder.applyLights 的白天值）
    public static let day = SkyLook(horizon: hex(0xD3DCE2), zenith: hex(0xA9BCCB), glow: hex(0xFFB070), glowAmount: 0, ground: hex(0xA4ABB0),
                                    keyColor: hex(0xFFEBD2), keyIntensity: 600, ambientColor: hex(0xDCE6F0), ambientIntensity: 660,
                                    fill: 340, moonFill: 0, dark: 0, lamps: 0, sunDir: nil)
    /// 改版前的夜晚
    public static let night = SkyLook(horizon: hex(0x141B26), zenith: hex(0x070A10), glow: hex(0x6A4A78), glowAmount: 0, ground: hex(0x0D1218),
                                      keyColor: hex(0xA9B8DE), keyIntensity: 460, ambientColor: hex(0x8E9CC4), ambientIntensity: 260,
                                      fill: 0, moonFill: 1500, dark: 1, lamps: 1, sunDir: nil)

    public var isNight: Bool { dark >= 0.5 }

    /// 一個關鍵格：仰角 e 時的值（主光：太陽在 e ≥ −4° 時、月光在 e < −4° 時；換方向那一格強度是 0，不會跳）
    struct Key {
        var e: Double
        var hor: UInt32, zen: UInt32, glow: UInt32, glowA: Double, ground: UInt32
        var key: UInt32, keyI: Double, amb: UInt32, ambI: Double
        var fill: Double, moon: Double, dark: Double, lamps: Double
    }

    // 清晨：夜 →（−12～−6 天空漸亮、偏藍紫）→ 日出（−6～+6 地平線暖橘粉、主光低角度橘紅）→ 上午 → 白天
    static let morning: [Key] = [
        Key(e: -12, hor: 0x141B26, zen: 0x070A10, glow: 0x3A3060, glowA: 0, ground: 0x0D1218, key: 0xA9B8DE, keyI: 460, amb: 0x8E9CC4, ambI: 260, fill: 0, moon: 1500, dark: 1, lamps: 1),
        Key(e: -9, hor: 0x252A44, zen: 0x0C1020, glow: 0x4A3C70, glowA: 0.35, ground: 0x111724, key: 0xA9B8DE, keyI: 330, amb: 0x8E9CC6, ambI: 290, fill: 0, moon: 1250, dark: 0.95, lamps: 1),
        Key(e: -6, hor: 0x4A4670, zen: 0x18223E, glow: 0x8A6A9A, glowA: 0.5, ground: 0x1A2030, key: 0xA9B8DE, keyI: 160, amb: 0x9298C8, ambI: 340, fill: 40, moon: 800, dark: 0.82, lamps: 0.92),
        Key(e: -4, hor: 0x7A6A8E, zen: 0x283652, glow: 0xC8889A, glowA: 0.6, ground: 0x363A52, key: 0xFF9A70, keyI: 0, amb: 0xA6A0C8, ambI: 420, fill: 80, moon: 450, dark: 0.68, lamps: 0.78),
        Key(e: -1.5, hor: 0xC08890, zen: 0x46587A, glow: 0xF4A07C, glowA: 0.8, ground: 0x606278, key: 0xFF8A5A, keyI: 220, amb: 0xBCAEC6, ambI: 490, fill: 150, moon: 120, dark: 0.48, lamps: 0.5),
        Key(e: 1, hor: 0xE6A088, zen: 0x6A82A6, glow: 0xFFA868, glowA: 0.9, ground: 0x80828C, key: 0xFF9C5E, keyI: 420, amb: 0xCABCC8, ambI: 555, fill: 210, moon: 0, dark: 0.3, lamps: 0.22),
        Key(e: 4, hor: 0xEAB898, zen: 0x86A0BE, glow: 0xFFBC80, glowA: 0.7, ground: 0x8A8E90, key: 0xFFB27A, keyI: 520, amb: 0xD2CCD2, ambI: 580, fill: 270, moon: 0, dark: 0.14, lamps: 0.04),
        Key(e: 8, hor: 0xDECCBC, zen: 0x98B0C4, glow: 0xFFD0A0, glowA: 0.4, ground: 0x9A9FA2, key: 0xFFCDA0, keyI: 570, amb: 0xD8DCE2, ambI: 630, fill: 310, moon: 0, dark: 0.04, lamps: 0),
        Key(e: 15, hor: 0xD6D8DA, zen: 0xA4BAC9, glow: 0xFFE0C0, glowA: 0.12, ground: 0xA2A9AE, key: 0xFFE2C4, keyI: 595, amb: 0xDAE4EE, ambI: 655, fill: 335, moon: 0, dark: 0, lamps: 0),
        Key(e: 22, hor: 0xD3DCE2, zen: 0xA9BCCB, glow: 0xFFB070, glowA: 0, ground: 0xA4ABB0, key: 0xFFEBD2, keyI: 600, amb: 0xDCE6F0, ambI: 660, fill: 340, moon: 0, dark: 0, lamps: 0),
    ]
    // 傍晚：白天 → 金黃時段（+10～0）→ 日落（0～−6 橘紅轉紫）→ 夜
    static let evening: [Key] = [
        Key(e: -12, hor: 0x141B26, zen: 0x070A10, glow: 0x3A2A50, glowA: 0, ground: 0x0D1218, key: 0xA9B8DE, keyI: 460, amb: 0x8E9CC4, ambI: 260, fill: 0, moon: 1500, dark: 1, lamps: 1),
        Key(e: -9, hor: 0x2A2644, zen: 0x0D1020, glow: 0x5A3A6A, glowA: 0.4, ground: 0x121624, key: 0xA9B8DE, keyI: 330, amb: 0x8E9AC6, ambI: 290, fill: 0, moon: 1250, dark: 0.95, lamps: 1),
        Key(e: -6, hor: 0x5A426E, zen: 0x1C2242, glow: 0xA05A78, glowA: 0.6, ground: 0x1C1E2C, key: 0xA9B8DE, keyI: 160, amb: 0x9894C4, ambI: 340, fill: 40, moon: 800, dark: 0.82, lamps: 0.9),
        Key(e: -4, hor: 0x8E5A78, zen: 0x2C3456, glow: 0xD06A6A, glowA: 0.75, ground: 0x3A3E56, key: 0xFF7A50, keyI: 0, amb: 0xA098C0, ambI: 420, fill: 80, moon: 450, dark: 0.68, lamps: 0.75),
        Key(e: -1.5, hor: 0xD07A6E, zen: 0x4A5478, glow: 0xF48058, glowA: 0.9, ground: 0x66667C, key: 0xFF7448, keyI: 240, amb: 0xB8A8C0, ambI: 500, fill: 150, moon: 120, dark: 0.48, lamps: 0.45),
        Key(e: 1, hor: 0xEC9466, zen: 0x6C7EA0, glow: 0xFF8C4A, glowA: 1, ground: 0x84828A, key: 0xFF8648, keyI: 440, amb: 0xD2B4AC, ambI: 560, fill: 220, moon: 0, dark: 0.28, lamps: 0.22),
        Key(e: 4, hor: 0xEEAE76, zen: 0x88A0BC, glow: 0xFFA458, glowA: 0.8, ground: 0x8E8C8A, key: 0xFFA25C, keyI: 540, amb: 0xD8C4B6, ambI: 580, fill: 280, moon: 0, dark: 0.12, lamps: 0.06),
        Key(e: 10, hor: 0xE4CCA8, zen: 0x9CB2C4, glow: 0xFFC27A, glowA: 0.45, ground: 0x9EA2A2, key: 0xFFC890, keyI: 590, amb: 0xDCD8D6, ambI: 635, fill: 320, moon: 0, dark: 0.02, lamps: 0),
        Key(e: 16, hor: 0xD8D8D6, zen: 0xA6BAC9, glow: 0xFFD8A8, glowA: 0.15, ground: 0xA3AAAE, key: 0xFFE0BC, keyI: 598, amb: 0xDBE3EC, ambI: 655, fill: 336, moon: 0, dark: 0, lamps: 0),
        Key(e: 22, hor: 0xD3DCE2, zen: 0xA9BCCB, glow: 0xFFB070, glowA: 0, ground: 0xA4ABB0, key: 0xFFEBD2, keyI: 600, amb: 0xDCE6F0, ambI: 660, fill: 340, moon: 0, dark: 0, lamps: 0),
    ]
    /// 主光從太陽換成月光的仰角（這一格強度是 0）
    public static let keySwitch = -4.0

    /// 依太陽位置混合（仰角 ≥ 22° 就是白天、≤ −12° 就是夜晚，跟改版前一模一樣）
    public static func at(_ s: SunSample) -> SkyLook {
        let t = s.rising ? morning : evening
        let e = s.elevation
        if e >= t.last!.e { var d = day; d.sunDir = SunDir(elevation: max(3, e), azimuth: s.azimuth); return d }
        if e <= t.first!.e { return night }
        let i = t.firstIndex { $0.e > e }!
        let a = t[i - 1], b = t[i]
        let f = (e - a.e) / (b.e - a.e)
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * f }
        func mixC(_ x: UInt32, _ y: UInt32) -> RGB { let p = hex(x), q = hex(y); return p + (q - p) * f }
        return SkyLook(horizon: mixC(a.hor, b.hor), zenith: mixC(a.zen, b.zen), glow: mixC(a.glow, b.glow), glowAmount: mix(a.glowA, b.glowA),
                       ground: mixC(a.ground, b.ground), keyColor: e >= keySwitch ? mixC(a.key, b.key) : hex(0xA9B8DE), keyIntensity: mix(a.keyI, b.keyI),
                       ambientColor: mixC(a.amb, b.amb), ambientIntensity: mix(a.ambI, b.ambI), fill: mix(a.fill, b.fill), moonFill: mix(a.moon, b.moon),
                       dark: mix(a.dark, b.dark), lamps: mix(a.lamps, b.lamps),
                       sunDir: e >= keySwitch ? SunDir(elevation: max(3, e), azimuth: s.azimuth) : nil)
    }

    /// 給「自動・xx」那個標籤看的時段名稱
    public static func phaseTitle(_ s: SunSample) -> String {
        let e = s.elevation
        if e <= -12 { return "夜晚" }
        if e < -4 { return s.rising ? "清晨" : "黃昏" }
        if s.rising { return e < 6 ? "日出" : "白天" }
        if e < 1 { return "日落" }
        if e < 15 { return "傍晚" }
        return "白天"
    }
}
