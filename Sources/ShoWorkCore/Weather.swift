import Foundation

// 真實天氣（10-21：3D 科技大樓跟著外面的天氣變，起因是颱風天 Kang 問「是不是有什麼關聯可以處理」）。
// 10-23：學弟的 commit 加了龜山、桃園機場，三地並排（`WeatherSite`）。
// 10-25 Kang：三地天氣都一樣、不要放一排 ⇒ 預設只看台北；地點每個人自己選（搜尋任何城市，`WeatherSite`＋`Geocode`）。
// 資料：Open-Meteo（https://open-meteo.com，免金鑰）的 current 欄位；這裡只放純函式：解析 JSON、分類、對映成畫面參數。
// 抓資料（每 10 分鐘、失敗保留上次）在 ShoWorkAgent/OfficeWeather.swift。規範 §3.8.2。

/// 一次觀測（風速一律 m/s、雨量一律 mm/h）
public struct WeatherNow: Equatable, Sendable {
    /// WMO weather code（https://open-meteo.com/en/docs 的 WMO Weather interpretation codes）
    public var code: Int
    /// 降雨強度 mm/h（Open-Meteo current 的 precipitation 是前一個 interval（15 分鐘）的累積，已換算成每小時）
    public var rainRate: Double
    /// 雲量 %（0–100）
    public var cloudCover: Double
    /// 10 公尺平均風速、陣風（m/s）
    public var wind: Double, gust: Double
    public init(code: Int, rainRate: Double, cloudCover: Double, wind: Double, gust: Double) {
        self.code = code; self.rainRate = rainRate; self.cloudCover = cloudCover; self.wind = wind; self.gust = gust
    }

    public var kind: WeatherKind { WeatherKind.classify(self) }
    /// 「大雨 · 陣風 43 km/h」
    public var brief: String { "\(kind.title) · 陣風 \(Int((gust * 3.6).rounded())) km/h" }
    /// 「龜山 大雨 · 陣風 43 km/h」
    public func summary(_ site: WeatherSite) -> String { "\(site.title) \(brief)" }
}

/// 看天氣的地點（10-25 Kang：「設計成個人可以選擇位置」）：每台電腦自己存一份清單（office.weatherPlaces），
/// 可以搜尋任何城市加進來（`Geocode`，Open-Meteo 地名搜尋）；清單第一個是主天氣（畫面的雲、雨、颱風跟著它）。預設只有台北。
public struct WeatherSite: Codable, Hashable, Sendable {
    public var title: String
    /// 座標（存小數兩位，Open-Meteo 格點約 1–2 公里，再精細沒有意義）
    public var lat: Double, lon: Double
    /// 同名地點分辨用（「桃園市, 台灣」），搜尋結果才有
    public var detail: String?
    public init(title: String, lat: Double, lon: Double, detail: String? = nil) {
        self.title = title; self.lat = (lat * 100).rounded() / 100; self.lon = (lon * 100).rounded() / 100; self.detail = detail
    }
    public var coord: (lat: Double, lon: Double) { (lat, lon) }
    /// 「龜山, 桃園市, 台湾」
    public var fullName: String { [title, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ") }
    /// 同一個格點（小數兩位相同）＝同一個地方
    public func same(_ o: WeatherSite) -> Bool { lat == o.lat && lon == o.lon }

    public static let taipei = WeatherSite(title: "台北", lat: 25.03, lon: 121.56)       // 跟 Solar.taipei 同一點
    public static let guishan = WeatherSite(title: "龜山", lat: 25.00, lon: 121.34)      // 桃園市龜山區（10-23 學弟加的）
    public static let airport = WeatherSite(title: "桃園機場", lat: 25.08, lon: 121.23)  // 桃園國際機場（10-23 學弟加的）
    /// 測試變數 SHOWORK_OFFICE_WEATHER_SITES 用的名字
    public static let presets: [String: WeatherSite] = ["taipei": taipei, "guishan": guishan, "airport": airport]
    /// 預設只看台北（10-25 Kang）
    public static let defaults: [WeatherSite] = [.taipei]

    /// 最多幾個地點（每個地點每 10 分鐘一次請求，常駐程式不無限長；隊長 Penny 10-25）
    public static let limit = 5

    /// 讀存的清單；新格式沒有就看舊格式（ff3526e 存的預設地點名，例如 ["guishan","taipei"]）轉過來；都沒有、壞掉、空的 ⇒ 預設
    public static func load(_ data: Data?, legacy: [String]? = nil) -> [WeatherSite] {
        if let data, let xs = try? JSONDecoder().decode([WeatherSite].self, from: data), !xs.isEmpty { return Array(xs.prefix(limit)) }
        let old = ["guishan", "taipei", "airport"].filter { legacy?.contains($0) == true }.compactMap { presets[$0] }
        return old.isEmpty ? defaults : old
    }
    public static func save(_ xs: [WeatherSite]) -> Data { (try? JSONEncoder().encode(xs)) ?? Data() }

    /// 加進清單（同一個格點不重複加）
    public static func adding(_ x: WeatherSite, to xs: [WeatherSite]) -> [WeatherSite] { xs.contains { $0.same(x) } || xs.count >= limit ? xs : xs + [x] }
    /// 移除（至少留一個）
    public static func removing(_ x: WeatherSite, from xs: [WeatherSite]) -> [WeatherSite] { xs.count <= 1 ? xs : xs.filter { !$0.same(x) } }
    /// 設成主天氣＝搬到第一個
    public static func makingMain(_ x: WeatherSite, in xs: [WeatherSite]) -> [WeatherSite] { xs.filter { $0.same(x) } + xs.filter { !$0.same(x) } }
}

/// 地名搜尋（Open-Meteo Geocoding，免金鑰；中文地名可查，例如「龜山」會回新北、苗栗、高雄、桃園好幾個）
public enum Geocode {
    public static func url(_ q: String) -> URL? {
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2 else { return nil }          // API 要至少 2 個字
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [.init(name: "name", value: t), .init(name: "count", value: "8"), .init(name: "language", value: "zh"), .init(name: "format", value: "json")]
        return c.url
    }

    private struct Reply: Decodable {
        struct R: Decodable { var name: String; var latitude: Double; var longitude: Double; var admin1: String?; var admin2: String?; var country: String? }
        var results: [R]?
    }

    /// 結果 → 地點（最多 8 筆）；detail＝「行政區, 國家」（去掉跟名字一樣的、「臺灣省 or 台灣省」這種），清單顯示「城市, 行政區, 國家」
    public static func parse(_ d: Data) -> [WeatherSite] {
        guard let r = try? JSONDecoder().decode(Reply.self, from: d) else { return [] }
        var out: [WeatherSite] = []
        for x in r.results ?? [] {
            var parts: [String] = []
            for p in [x.admin2, x.admin1, x.country].compactMap({ $0 }) where !p.isEmpty && p != x.name && !p.contains(" or ") && !parts.contains(p) { parts.append(p) }
            let s = WeatherSite(title: x.name, lat: x.latitude, lon: x.longitude, detail: parts.prefix(2).joined(separator: ", "))
            if !out.contains(where: { $0.same(s) || $0.fullName == s.fullName }) { out.append(s) }   // 同格點、或顯示起來一模一樣（苗栗縣有兩個「龜山」）只留第一個
        }
        return Array(out.prefix(8))
    }
}

public enum WeatherKind: String, Sendable, CaseIterable {
    case clear, cloudy, overcast, lightRain, heavyRain, thunder, typhoon

    /// 下雨（休息的人不上頂樓，改去一樓咖啡館）
    public var isWet: Bool { [.lightRain, .heavyRain, .thunder, .typhoon].contains(self) }

    public var title: String {
        switch self {
        case .clear: return "晴"
        case .cloudy: return "多雲"
        case .overcast: return "陰"
        case .lightRain: return "小雨"
        case .heavyRain: return "大雨"
        case .thunder: return "雷雨"
        case .typhoon: return "颱風級強風"
        }
    }

    /// 颱風級強風的門檻（m/s）。出處：蒲福風級表（中央氣象署）——
    /// 陣風 ≥ 17.2 m/s＝8 級（中央氣象署「陸上強風特報」的陣風門檻、颱風暴風圈的定義風速 34 kt）；
    /// 平均風 ≥ 13.9 m/s＝7 級（強風）下限。兩個任一個達到就算颱風級
    public static let typhoonGust = 17.2, typhoonWind = 13.9
    /// 大雨的降雨強度門檻 mm/h。出處：美國氣象學會（AMS）Glossary「heavy rain」≥ 7.6 mm/h（0.30 in/h）；
    /// 中央氣象署的「大雨」是 24 小時 80 mm／1 小時 40 mm，是警報級、太高，畫面用 AMS 的強度分級
    public static let heavyRate = 7.6
    /// 有在下雨的最低強度 mm/h（Open-Meteo 雨量解析度 0.1 mm／15 分鐘 ≈ 0.4 mm/h，低於這個當沒下）
    public static let rainRate = 0.1

    static let thunderCodes: Set<Int> = [95, 96, 99]
    /// 大雨／暴雨：65 大雨、67 強凍雨、82 強陣雨、75 大雪、86 強陣雪（台北不下雪，當雨）
    static let heavyCodes: Set<Int> = [65, 67, 75, 82, 86]
    /// 有降水的代碼：51–57 毛毛雨、61–67 雨、71–77 雪、80–82 陣雨、85–86 陣雪
    static func rainy(_ c: Int) -> Bool { (51...67).contains(c) || (71...77).contains(c) || (80...82).contains(c) || c == 85 || c == 86 }

    public static func classify(_ w: WeatherNow) -> WeatherKind {
        if w.gust >= typhoonGust || w.wind >= typhoonWind { return .typhoon }
        if thunderCodes.contains(w.code) { return .thunder }
        if heavyCodes.contains(w.code) || w.rainRate >= heavyRate { return .heavyRain }
        if rainy(w.code) || w.rainRate >= rainRate { return .lightRain }
        if w.code == 3 || w.code == 45 || w.code == 48 || w.cloudCover >= 85 { return .overcast }
        if w.code == 2 || w.cloudCover >= 40 { return .cloudy }
        return .clear
    }

    /// 測試視窗的強制天氣（SHOWORK_OFFICE_WEATHER=clear|cloudy|overcast|rain|heavy|storm|typhoon）：每種一組代表性的觀測值
    public static func preset(_ name: String) -> WeatherNow? {
        switch name {
        case "clear": return WeatherNow(code: 0, rainRate: 0, cloudCover: 5, wind: 2, gust: 4)
        case "cloudy": return WeatherNow(code: 2, rainRate: 0, cloudCover: 55, wind: 3, gust: 6)
        case "overcast": return WeatherNow(code: 3, rainRate: 0, cloudCover: 100, wind: 4, gust: 8)
        case "rain": return WeatherNow(code: 61, rainRate: 1.2, cloudCover: 100, wind: 4, gust: 8)
        case "heavy": return WeatherNow(code: 65, rainRate: 12, cloudCover: 100, wind: 6, gust: 12)
        case "storm": return WeatherNow(code: 95, rainRate: 16, cloudCover: 100, wind: 7, gust: 15)
        case "typhoon": return WeatherNow(code: 65, rainRate: 20, cloudCover: 100, wind: 18, gust: 33)
        default: return nil
        }
    }
}

// MARK: - Open-Meteo

public enum OpenMeteo {
    /// 某個地點的 current；風速要 m/s
    public static func url(_ site: WeatherSite) -> URL {
        let c = site.coord
        return URL(string: String(format: "https://api.open-meteo.com/v1/forecast?latitude=%.2f&longitude=%.2f", c.lat, c.lon)
            + "&current=weather_code,precipitation,rain,cloud_cover,wind_speed_10m,wind_gusts_10m&wind_speed_unit=ms")!
    }

    private struct Reply: Decodable {
        struct Current: Decodable {
            var interval: Double?
            var weather_code: Int?
            var precipitation: Double?
            var rain: Double?
            var cloud_cover: Double?
            var wind_speed_10m: Double?
            var wind_gusts_10m: Double?
        }
        struct Units: Decodable { var wind_speed_10m: String? }
        var current: Current
        var current_units: Units?
    }

    /// 解析 forecast?current=… 的回應；格式不對或缺天氣代碼回 nil（呼叫端保留上次結果）
    public static func parse(_ data: Data) -> WeatherNow? {
        guard let r = try? JSONDecoder().decode(Reply.self, from: data), let code = r.current.weather_code else { return nil }
        let c = r.current
        // 風速單位：要求的是 m/s；萬一回 km/h（參數被拿掉）也換算回來
        let k = (r.current_units?.wind_speed_10m ?? "m/s").lowercased().contains("km") ? 1 / 3.6 : 1
        // precipitation 是前一個 interval 的累積（current 預設 15 分鐘＝900 秒）⇒ 換成每小時
        let perHour = 3600 / max(60, c.interval ?? 900)
        let precip = max(c.precipitation ?? 0, c.rain ?? 0)
        let wind = (c.wind_speed_10m ?? 0) * k
        return WeatherNow(code: code, rainRate: precip * perHour, cloudCover: c.cloud_cover ?? 0,
                          wind: wind, gust: max(wind, (c.wind_gusts_10m ?? 0) * k))
    }
}

// MARK: - 對映成畫面參數

/// 天氣 → 畫面（疊在日出日落的 SkyLook 上，不取代）。clear ＝全部 0 ⇒ 畫面跟沒有天氣一模一樣
public struct WeatherLook: Equatable, Sendable {
    /// 雲：天空往灰色混、直射陽光變弱、假影子淡掉（0–1）
    public var cloud: Double = 0
    /// 暗：天色、環境光再壓暗（0–1）
    public var dim: Double = 0
    /// 雨量 0–1（決定粒子密度；0＝不下雨、不開粒子）
    public var rain: Double = 0
    /// 雨絲的水平/垂直比（風速決定；0＝垂直）
    public var tilt: Double = 0
    /// 雨落下的速度（場景單位/秒，誇張過，不是真實的 9 m/s）
    public var fallSpeed: Double = 30
    /// 暗天氣時城市燈提早亮一點（窗光、路燈；0–1，跟日出日落的 lamps 取大）
    public var lampBoost: Double = 0
    /// 雷雨：偶爾閃光
    public var lightning = false
    public var kind: WeatherKind = .clear

    public init() {}
    public static let clear = WeatherLook()

    public static func of(_ w: WeatherNow?) -> WeatherLook {
        guard let w else { return .clear }
        var l = WeatherLook(); l.kind = w.kind
        let base = min(1, log1p(max(0, w.rainRate)) / log1p(40))     // 1 mm/h ≈ 0.19、12 ≈ 0.69、40 mm/h 以上 1
        func rain(_ minimum: Double) -> Double { min(1, max(base, minimum)) }
        switch l.kind {
        case .clear: return .clear
        case .cloudy: l.cloud = 0.15 + 0.3 * min(1, w.cloudCover / 100); l.dim = 0.03
        case .overcast: l.cloud = 0.8; l.dim = 0.12
        case .lightRain: l.cloud = 0.85; l.dim = 0.2; l.rain = rain(0.22)
        case .heavyRain: l.cloud = 0.95; l.dim = 0.38; l.rain = rain(0.6); l.lampBoost = 0.2
        case .thunder: l.cloud = 1; l.dim = 0.48; l.rain = rain(0.6); l.lampBoost = 0.3; l.lightning = true
        case .typhoon: l.cloud = 1; l.dim = 0.56; l.rain = rain(0.75); l.lampBoost = 0.4; l.lightning = WeatherKind.thunderCodes.contains(w.code)
        }
        // 風：平均風與陣風混合；颱風級至少斜 1.4（約 55°）
        let eff = 0.6 * w.wind + 0.4 * w.gust
        l.tilt = min(1.8, eff / 14)
        if l.kind == .typhoon { l.tilt = max(1.4, l.tilt) }
        l.fallSpeed = 28 + 16 * l.rain + (l.kind == .typhoon ? 10 : 0)
        return l
    }
}

extension SkyLook {
    /// 疊上天氣：天空往灰混、主光變弱變中性、環境光略壓暗、地面變暗（濕）、暗天氣城市燈提早亮。晴天回原值（像素不變）
    public func weathered(_ w: WeatherLook) -> SkyLook {
        guard w.cloud > 0 || w.dim > 0 else { return self }
        var s = self
        let c = w.cloud, d = w.dim
        func mix(_ a: RGB, _ b: RGB, _ f: Double) -> RGB { a + (b - a) * f }
        func lum(_ x: RGB) -> Double { x.x * 0.2126 + x.y * 0.7152 + x.z * 0.0722 }
        let tint = RGB(0.95, 0.98, 1.03)           // 雨天的灰略偏冷
        let hor = RGB(repeating: lum(horizon)) * tint * (1 - 0.55 * d)
        s.horizon = mix(horizon, hor, c)
        s.zenith = mix(zenith, hor * 0.9, c)       // 陰天整片天幾乎一樣灰，天頂稍暗
        s.glowAmount = glowAmount * (1 - c)
        s.ground = mix(ground, ground * (1 - 0.45 * d), c)
        s.keyIntensity = keyIntensity * (1 - 0.7 * c)
        s.keyColor = mix(keyColor, SkyLook.hex(0xE4E8EE), c)
        s.ambientIntensity = ambientIntensity * (1 + 0.15 * c) * max(0.35, 1 - 1.1 * d)
        s.ambientColor = mix(ambientColor, SkyLook.hex(0xC8D0DA), c * 0.7)
        s.fill = fill * (1 - 0.4 * c) * max(0.2, 1 - 1.2 * d)
        s.moonFill = moonFill * (1 - 0.5 * c)
        if dark < 0.45 { s.dark = min(0.45, dark + 0.9 * d) }     // 白天變暗但不會被當成夜晚（isNight 是 ≥ 0.5）
        s.lamps = max(lamps, w.lampBoost)
        s.overcast = c
        return s
    }
}
