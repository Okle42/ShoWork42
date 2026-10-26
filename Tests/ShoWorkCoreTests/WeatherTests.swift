import Foundation
import simd
import Testing
@testable import ShoWorkCore

@Suite struct WeatherTests {
    func w(_ code: Int, rain: Double = 0, cloud: Double = 0, wind: Double = 2, gust: Double = 4) -> WeatherNow {
        WeatherNow(code: code, rainRate: rain, cloudCover: cloud, wind: wind, gust: gust)
    }

    @Test func classify() {
        #expect(w(0).kind == .clear)
        #expect(w(1, cloud: 20).kind == .clear)
        #expect(w(2, cloud: 50).kind == .cloudy)
        #expect(w(1, cloud: 60).kind == .cloudy)
        #expect(w(3, cloud: 100).kind == .overcast)
        #expect(w(45).kind == .overcast)
        #expect(w(61, rain: 0.8).kind == .lightRain)
        #expect(w(80).kind == .lightRain)
        #expect(w(3, rain: 0.4).kind == .lightRain)          // 代碼沒說下雨但有雨量
        #expect(w(63, rain: 8).kind == .heavyRain)           // 雨量 ≥ 7.6 mm/h
        #expect(w(65).kind == .heavyRain)
        #expect(w(82).kind == .heavyRain)
        #expect(w(95, rain: 2).kind == .thunder)
        #expect(w(99).kind == .thunder)
    }

    @Test func typhoonThresholds() {
        #expect(w(61, wind: 10, gust: 17.1).kind == .lightRain)
        #expect(w(61, wind: 10, gust: 17.2).kind == .typhoon)       // 陣風 8 級
        #expect(w(0, wind: 13.9, gust: 13.9).kind == .typhoon)      // 平均 7 級
        #expect(w(95, wind: 15, gust: 25).kind == .typhoon)         // 颱風級強風優先於雷雨
        #expect(WeatherLook.of(w(95, wind: 15, gust: 25)).lightning)
    }

    @Test func parseOpenMeteo() throws {
        let json = """
        {"latitude":25.0,"longitude":121.5,"current_units":{"time":"iso8601","interval":"seconds","weather_code":"wmo code",
         "precipitation":"mm","rain":"mm","cloud_cover":"%","wind_speed_10m":"m/s","wind_gusts_10m":"m/s"},
         "current":{"time":"2026-10-21T14:15","interval":900,"weather_code":65,"precipitation":3.0,"rain":2.9,
         "cloud_cover":100,"wind_speed_10m":15.2,"wind_gusts_10m":31.0}}
        """
        let n = try #require(OpenMeteo.parse(Data(json.utf8)))
        #expect(n.code == 65)
        #expect(abs(n.rainRate - 12) < 1e-9)          // 3 mm / 15 分鐘 = 12 mm/h
        #expect(n.wind == 15.2 && n.gust == 31)
        #expect(n.kind == .typhoon)
        #expect(n.summary(.taipei) == "台北 颱風級強風 · 陣風 112 km/h")
        #expect(n.summary(.guishan) == "龜山 颱風級強風 · 陣風 112 km/h")
        // 單位是 km/h 也換算
        let kmh = json.replacingOccurrences(of: "\"wind_speed_10m\":\"m/s\"", with: "\"wind_speed_10m\":\"km/h\"")
        let k = try #require(OpenMeteo.parse(Data(kmh.utf8)))
        #expect(abs(k.wind - 15.2 / 3.6) < 1e-9)
        // 壞資料回 nil（呼叫端保留上次）
        #expect(OpenMeteo.parse(Data("{\"error\":true}".utf8)) == nil)
        #expect(OpenMeteo.parse(Data("not json".utf8)) == nil)
        #expect(OpenMeteo.url(.guishan).absoluteString.contains("wind_speed_unit=ms"))
    }

    @Test func sites() {
        #expect(OpenMeteo.url(.guishan).absoluteString.contains("latitude=25.00&longitude=121.34"))
        #expect(OpenMeteo.url(.taipei).absoluteString.contains("latitude=25.03&longitude=121.56"))
        #expect(OpenMeteo.url(.airport).absoluteString.contains("latitude=25.08&longitude=121.23"))
        // 10-25：預設只看台北；存的清單照存的順序（第一個是主天氣）
        #expect(WeatherSite.load(nil) == [.taipei])
        #expect(WeatherSite.load(Data("壞掉".utf8)) == [.taipei])
        #expect(WeatherSite.load(WeatherSite.save([])) == [.taipei])
        let k = WeatherSite(title: "高雄市", lat: 22.61626, lon: 120.31333, detail: "高雄市, 台湾")
        #expect(k.lat == 22.62 && k.lon == 120.31)                                  // 存小數兩位
        #expect(WeatherSite.load(WeatherSite.save([k, .taipei])) == [k, .taipei])
        // 舊格式（ff3526e 的預設地點名）遷移；新格式優先
        #expect(WeatherSite.load(nil, legacy: ["airport", "guishan"]) == [.guishan, .airport])
        #expect(WeatherSite.load(nil, legacy: ["火星"]) == [.taipei])
        #expect(WeatherSite.load(WeatherSite.save([k]), legacy: ["guishan"]) == [k])
        // 加入不重複、上限 5、移除至少留一個、換主天氣
        var xs = WeatherSite.adding(.taipei, to: [.taipei])
        #expect(xs == [.taipei])
        for i in 0..<8 { xs = WeatherSite.adding(WeatherSite(title: "地點\(i)", lat: Double(i), lon: 0), to: xs) }
        #expect(xs.count == WeatherSite.limit)
        #expect(WeatherSite.load(WeatherSite.save(xs + [k])).count == WeatherSite.limit)
        #expect(WeatherSite.removing(.taipei, from: [.taipei]) == [.taipei])
        #expect(WeatherSite.removing(.taipei, from: [.taipei, k]) == [k])
        #expect(WeatherSite.makingMain(k, in: [.taipei, .guishan, k]) == [k, .taipei, .guishan])
    }

    @Test func geocode() throws {
        #expect(Geocode.url("台") == nil)                                           // 至少 2 個字
        let u = try #require(Geocode.url(" 龜山 "))
        #expect(u.absoluteString.contains("count=8") && u.absoluteString.contains("language=zh"))
        let json = """
        {"results":[{"name":"龜山","latitude":24.99436,"longitude":121.33672,"admin1":"臺灣省 or 台灣省","admin2":"桃園市","country":"台湾"},
                    {"name":"龜山","latitude":24.90224,"longitude":121.55245,"admin1":"臺北市","admin2":"新北市","country":"台湾"},
                    {"name":"龜山","latitude":24.902,"longitude":121.553,"admin1":"臺北市","admin2":"新北市","country":"台湾"},
                    {"name":"龜山","latitude":24.4177,"longitude":120.8635,"admin1":"臺灣省 or 台灣省","admin2":"苗栗縣","country":"台湾"},
                    {"name":"龜山","latitude":24.54025,"longitude":120.81696,"admin1":"臺灣省 or 台灣省","admin2":"苗栗縣","country":"台湾"},
                    {"name":"高雄市","latitude":22.61626,"longitude":120.31333,"admin1":"高雄市","admin2":"高雄市","country":"台湾"}]}
        """
        let r = Geocode.parse(Data(json.utf8))
        #expect(r.map(\.fullName) == ["龜山, 桃園市, 台湾", "龜山, 新北市, 臺北市", "龜山, 苗栗縣, 台湾", "高雄市, 台湾"])   // 同格點去重、同名看得出差別
        #expect(Geocode.parse(Data("{}".utf8)).isEmpty && Geocode.parse(Data("x".utf8)).isEmpty)
        let many = "{\"results\":[" + (0..<12).map { "{\"name\":\"甲\($0)\",\"latitude\":\($0),\"longitude\":1}" }.joined(separator: ",") + "]}"
        #expect(Geocode.parse(Data(many.utf8)).count == 8)
    }

    @Test func presets() {
        let names = ["clear", "cloudy", "overcast", "rain", "heavy", "storm", "typhoon"]
        let kinds: [WeatherKind] = [.clear, .cloudy, .overcast, .lightRain, .heavyRain, .thunder, .typhoon]
        for (n, k) in zip(names, kinds) { #expect(WeatherKind.preset(n)?.kind == k) }
        #expect(WeatherKind.preset("snow") == nil)
    }

    @Test func clearLeavesSkyUntouched() {
        #expect(SkyLook.day.weathered(.clear) == .day)
        #expect(SkyLook.night.weathered(.clear) == .night)
        #expect(SkyLook.day.weathered(.of(w(0, cloud: 20))) == .day)
        #expect(SkyLook.day.weathered(.of(nil)) == .day)
        #expect(WeatherLook.of(w(0)).rain == 0)
    }

    @Test func worseWeatherIsDarker() {
        func lum(_ c: SIMD3<Double>) -> Double { c.x * 0.2126 + c.y * 0.7152 + c.z * 0.0722 }
        var prev = SkyLook.day
        for n in ["cloudy", "overcast", "rain", "heavy", "storm", "typhoon"] {
            let l = SkyLook.day.weathered(.of(WeatherKind.preset(n)))
            #expect(lum(l.horizon) <= lum(prev.horizon) + 1e-9, "\(n)")
            #expect(l.keyIntensity <= prev.keyIntensity + 1e-9, "\(n)")
            #expect(!l.isNight, "\(n) 白天不能被當成夜晚")
            prev = l
        }
        // 下雨才有雨；颱風雨最斜、最密
        let rain = WeatherLook.of(WeatherKind.preset("rain")), ty = WeatherLook.of(WeatherKind.preset("typhoon"))
        #expect(WeatherLook.of(WeatherKind.preset("overcast")).rain == 0)
        #expect(rain.rain > 0 && ty.rain > rain.rain && ty.tilt > rain.tilt && ty.tilt >= 1.4)
        #expect(WeatherLook.of(WeatherKind.preset("storm")).lightning && !rain.lightning)
        // 夜晚：暗度不變（還是夜）
        #expect(SkyLook.night.weathered(ty).dark == 1)
    }
}
