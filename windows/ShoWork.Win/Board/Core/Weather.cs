using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ShoWork;

// Mac 版 Sources/ShoWorkCore/Weather.swift 的逐行轉寫（11-02 P8）。
// 真實天氣（10-21：3D 科技大樓跟著外面的天氣變，起因是颱風天 Kang 問「是不是有什麼關聯可以處理」）。
// 10-25 Kang：預設只看台北；地點每個人自己選（搜尋任何城市，`WeatherSite`＋`Geocode`）。
// 資料：Open-Meteo（https://open-meteo.com，免金鑰）的 current 欄位；這裡只放純函式：解析 JSON、分類、對映成畫面參數。
// 抓資料（每 10 分鐘、失敗保留上次）在 Board/Source/WeatherSource.cs（Mac：ShoWorkAgent/OfficeWeather.swift）。規範 §3.8.2。

/// 一次觀測（風速一律 m/s、雨量一律 mm/h）
public sealed record WeatherNow
{
    /// WMO weather code
    public int Code { get; set; }
    /// 降雨強度 mm/h（Open-Meteo current 的 precipitation 是前一個 interval（15 分鐘）的累積，已換算成每小時）
    public double RainRate { get; set; }
    /// 雲量 %（0–100）
    public double CloudCover { get; set; }
    /// 10 公尺平均風速、陣風（m/s）
    public double Wind { get; set; }
    public double Gust { get; set; }
    public WeatherNow(int code, double rainRate, double cloudCover, double wind, double gust) { Code = code; RainRate = rainRate; CloudCover = cloudCover; Wind = wind; Gust = gust; }

    public WeatherKind kind => WeatherKinds.classify(this);
    /// 「大雨 · 陣風 43 km/h」
    public string brief => $"{kind.title()} · 陣風 {(int)Math.Round(Gust * 3.6, MidpointRounding.AwayFromZero)} km/h";
    /// 「龜山 大雨 · 陣風 43 km/h」
    public string summary(WeatherSite site) => $"{site.Title} {brief}";
}

/// 看天氣的地點（10-25 Kang：「設計成個人可以選擇位置」）：每台電腦自己存一份清單，
/// 可以搜尋任何城市加進來（`Geocode`）；清單第一個是主天氣（畫面的雲、雨、颱風跟著它）。預設只有台北。
public sealed record WeatherSite
{
    public string Title { get; set; } = "";
    /// 座標（存小數兩位，Open-Meteo 格點約 1–2 公里，再精細沒有意義）
    public double Lat { get; set; }
    public double Lon { get; set; }
    /// 同名地點分辨用（「桃園市, 台灣」），搜尋結果才有
    public string? Detail { get; set; }
    public WeatherSite() { }
    public WeatherSite(string title, double lat, double lon, string? detail = null)
    {
        Title = title; Lat = Math.Round(lat * 100, MidpointRounding.AwayFromZero) / 100; Lon = Math.Round(lon * 100, MidpointRounding.AwayFromZero) / 100; Detail = detail;
    }
    public (double lat, double lon) coord => (Lat, Lon);
    /// 「龜山, 桃園市, 台湾」
    public string fullName => string.Join(", ", new[] { Title, Detail }.Where(x => !string.IsNullOrEmpty(x)));
    /// 同一個格點（小數兩位相同）＝同一個地方
    public bool same(WeatherSite o) => Lat == o.Lat && Lon == o.Lon;

    public static readonly WeatherSite taipei = new("台北", 25.03, 121.56);        // 跟 Solar.taipei 同一點
    public static readonly WeatherSite guishan = new("龜山", 25.00, 121.34);       // 桃園市龜山區（10-23 學弟加的）
    public static readonly WeatherSite airport = new("桃園機場", 25.08, 121.23);   // 桃園國際機場（10-23 學弟加的）
    /// 測試變數 SHOWORK_OFFICE_WEATHER_SITES 用的名字
    public static readonly Dictionary<string, WeatherSite> presets = new() { ["taipei"] = taipei, ["guishan"] = guishan, ["airport"] = airport };
    /// 預設只看台北（10-25 Kang）
    public static List<WeatherSite> defaults => new() { taipei };

    /// 最多幾個地點（每個地點每 10 分鐘一次請求，常駐程式不無限長；隊長 Penny 10-25）
    public const int limit = 5;

    static readonly JsonSerializerOptions Opt = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    /// 讀存的清單；沒有、壞掉、空的 ⇒ 預設
    public static List<WeatherSite> load(string? data)
    {
        try
        {
            if (data != null && JsonSerializer.Deserialize<List<WeatherSite>>(data, Opt) is { Count: > 0 } xs) return xs.Take(limit).ToList();
        }
        catch { }
        return defaults;
    }
    public static string save(List<WeatherSite> xs) => JsonSerializer.Serialize(xs, Opt);

    /// 加進清單（同一個格點不重複加）
    public static List<WeatherSite> adding(WeatherSite x, List<WeatherSite> xs) => xs.Any(s => s.same(x)) || xs.Count >= limit ? xs : xs.Append(x).ToList();
    /// 移除（至少留一個）
    public static List<WeatherSite> removing(WeatherSite x, List<WeatherSite> xs) => xs.Count <= 1 ? xs : xs.Where(s => !s.same(x)).ToList();
    /// 設成主天氣＝搬到第一個
    public static List<WeatherSite> makingMain(WeatherSite x, List<WeatherSite> xs) => xs.Where(s => s.same(x)).Concat(xs.Where(s => !s.same(x))).ToList();
}

/// 地名搜尋（Open-Meteo Geocoding，免金鑰）
public static class Geocode
{
    public static string? url(string q)
    {
        var t = q.Trim();
        if (t.Length < 2) return null;          // API 要至少 2 個字
        return "https://geocoding-api.open-meteo.com/v1/search?name=" + Uri.EscapeDataString(t) + "&count=8&language=zh&format=json";
    }

    /// 結果 → 地點（最多 8 筆）；detail＝「行政區, 國家」（去掉跟名字一樣的、「臺灣省 or 台灣省」這種）
    public static List<WeatherSite> parse(string d)
    {
        var out_ = new List<WeatherSite>();
        try
        {
            if (JsonNode.Parse(d)?["results"] is not JsonArray rs) return out_;
            foreach (var x in rs.OfType<JsonObject>())
            {
                var name = x["name"]?.GetValue<string>(); if (name == null) continue;
                if (x["latitude"] is not JsonValue la || x["longitude"] is not JsonValue lo) continue;
                var parts = new List<string>();
                foreach (var k in new[] { "admin2", "admin1", "country" })
                    if (x[k] is JsonValue v && v.TryGetValue<string>(out var p) && p.Length > 0 && p != name && !p.Contains(" or ") && !parts.Contains(p)) parts.Add(p);
                var s = new WeatherSite(name, la.GetValue<double>(), lo.GetValue<double>(), string.Join(", ", parts.Take(2)));
                if (!out_.Any(o => o.same(s) || o.fullName == s.fullName)) out_.Add(s);   // 同格點、或顯示起來一模一樣只留第一個
            }
        }
        catch { }
        return out_.Take(8).ToList();
    }
}

public enum WeatherKind { Clear, Cloudy, Overcast, LightRain, HeavyRain, Thunder, Typhoon }

public static class WeatherKinds
{
    /// 下雨（休息的人不上頂樓，改去一樓咖啡館）
    public static bool isWet(this WeatherKind k) => k is WeatherKind.LightRain or WeatherKind.HeavyRain or WeatherKind.Thunder or WeatherKind.Typhoon;

    public static string title(this WeatherKind k) => k switch
    {
        WeatherKind.Clear => "晴", WeatherKind.Cloudy => "多雲", WeatherKind.Overcast => "陰", WeatherKind.LightRain => "小雨",
        WeatherKind.HeavyRain => "大雨", WeatherKind.Thunder => "雷雨", _ => "颱風級強風",
    };

    /// 颱風級強風的門檻（m/s）。出處：蒲福風級表（中央氣象署）——陣風 ≥ 17.2 m/s＝8 級、平均風 ≥ 13.9 m/s＝7 級下限。兩個任一個達到就算颱風級
    public const double typhoonGust = 17.2, typhoonWind = 13.9;
    /// 大雨的降雨強度門檻 mm/h。出處：美國氣象學會（AMS）Glossary「heavy rain」≥ 7.6 mm/h
    public const double heavyRate = 7.6;
    /// 有在下雨的最低強度 mm/h（Open-Meteo 雨量解析度 0.1 mm／15 分鐘 ≈ 0.4 mm/h，低於這個當沒下）
    public const double rainRate = 0.1;

    internal static readonly HashSet<int> thunderCodes = new() { 95, 96, 99 };
    /// 大雨／暴雨：65 大雨、67 強凍雨、82 強陣雨、75 大雪、86 強陣雪（台北不下雪，當雨）
    static readonly HashSet<int> heavyCodes = new() { 65, 67, 75, 82, 86 };
    /// 有降水的代碼：51–57 毛毛雨、61–67 雨、71–77 雪、80–82 陣雨、85–86 陣雪
    static bool rainy(int c) => (c >= 51 && c <= 67) || (c >= 71 && c <= 77) || (c >= 80 && c <= 82) || c == 85 || c == 86;

    public static WeatherKind classify(WeatherNow w)
    {
        if (w.Gust >= typhoonGust || w.Wind >= typhoonWind) return WeatherKind.Typhoon;
        if (thunderCodes.Contains(w.Code)) return WeatherKind.Thunder;
        if (heavyCodes.Contains(w.Code) || w.RainRate >= heavyRate) return WeatherKind.HeavyRain;
        if (rainy(w.Code) || w.RainRate >= rainRate) return WeatherKind.LightRain;
        if (w.Code == 3 || w.Code == 45 || w.Code == 48 || w.CloudCover >= 85) return WeatherKind.Overcast;
        if (w.Code == 2 || w.CloudCover >= 40) return WeatherKind.Cloudy;
        return WeatherKind.Clear;
    }

    /// 測試視窗的強制天氣（SHOWORK_OFFICE_WEATHER=clear|cloudy|overcast|rain|heavy|storm|typhoon）：每種一組代表性的觀測值
    public static WeatherNow? preset(string name) => name switch
    {
        "clear" => new WeatherNow(0, 0, 5, 2, 4),
        "cloudy" => new WeatherNow(2, 0, 55, 3, 6),
        "overcast" => new WeatherNow(3, 0, 100, 4, 8),
        "rain" => new WeatherNow(61, 1.2, 100, 4, 8),
        "heavy" => new WeatherNow(65, 12, 100, 6, 12),
        "storm" => new WeatherNow(95, 16, 100, 7, 15),
        "typhoon" => new WeatherNow(65, 20, 100, 18, 33),
        _ => null,
    };
}

// MARK: - Open-Meteo

public static class OpenMeteo
{
    /// 某個地點的 current；風速要 m/s
    public static string url(WeatherSite site) =>
        string.Format(CultureInfo.InvariantCulture, "https://api.open-meteo.com/v1/forecast?latitude={0:F2}&longitude={1:F2}", site.Lat, site.Lon)
        + "&current=weather_code,precipitation,rain,cloud_cover,wind_speed_10m,wind_gusts_10m&wind_speed_unit=ms";

    /// 解析 forecast?current=… 的回應；格式不對或缺天氣代碼回 nil（呼叫端保留上次結果）
    public static WeatherNow? parse(string data)
    {
        try
        {
            if (JsonNode.Parse(data) is not JsonObject r || r["current"] is not JsonObject c) return null;
            double? D(string k) => c[k] is JsonValue v && v.TryGetValue<double>(out var x) ? x : null;
            if (D("weather_code") is not { } code) return null;
            // 風速單位：要求的是 m/s；萬一回 km/h（參數被拿掉）也換算回來
            var unit = (r["current_units"]?["wind_speed_10m"] as JsonValue)?.TryGetValue<string>(out var u) == true ? u : "m/s";
            double k = unit.ToLowerInvariant().Contains("km") ? 1 / 3.6 : 1;
            // precipitation 是前一個 interval 的累積（current 預設 15 分鐘＝900 秒）⇒ 換成每小時
            double perHour = 3600 / Math.Max(60, D("interval") ?? 900);
            double precip = Math.Max(D("precipitation") ?? 0, D("rain") ?? 0);
            double wind = (D("wind_speed_10m") ?? 0) * k;
            return new WeatherNow((int)code, precip * perHour, D("cloud_cover") ?? 0, wind, Math.Max(wind, (D("wind_gusts_10m") ?? 0) * k));
        }
        catch { return null; }
    }
}

// MARK: - 對映成畫面參數

/// 天氣 → 畫面（疊在日出日落的 SkyLook 上，不取代）。clear ＝全部 0 ⇒ 畫面跟沒有天氣一模一樣
public sealed record WeatherLook
{
    /// 雲：天空往灰色混、直射陽光變弱、假影子淡掉（0–1）
    public double Cloud { get; set; }
    /// 暗：天色、環境光再壓暗（0–1）
    public double Dim { get; set; }
    /// 雨量 0–1（決定粒子密度；0＝不下雨、不開粒子）
    public double Rain { get; set; }
    /// 雨絲的水平/垂直比（風速決定；0＝垂直）
    public double Tilt { get; set; }
    /// 雨落下的速度（場景單位/秒，誇張過，不是真實的 9 m/s）
    public double FallSpeed { get; set; } = 30;
    /// 暗天氣時城市燈提早亮一點（窗光、路燈；0–1，跟日出日落的 lamps 取大）
    public double LampBoost { get; set; }
    /// 雷雨：偶爾閃光
    public bool Lightning { get; set; }
    public WeatherKind Kind { get; set; } = WeatherKind.Clear;

    public static WeatherLook clear => new();

    public static WeatherLook of(WeatherNow? w)
    {
        if (w == null) return clear;
        var l = new WeatherLook { Kind = w.kind };
        double @base = Math.Min(1, Math.Log(1 + Math.Max(0, w.RainRate)) / Math.Log(1 + 40));     // 1 mm/h ≈ 0.19、12 ≈ 0.69、40 mm/h 以上 1
        double rain(double minimum) => Math.Min(1, Math.Max(@base, minimum));
        switch (l.Kind)
        {
            case WeatherKind.Clear: return clear;
            case WeatherKind.Cloudy: l.Cloud = 0.15 + 0.3 * Math.Min(1, w.CloudCover / 100); l.Dim = 0.03; break;
            case WeatherKind.Overcast: l.Cloud = 0.8; l.Dim = 0.12; break;
            case WeatherKind.LightRain: l.Cloud = 0.85; l.Dim = 0.2; l.Rain = rain(0.22); break;
            case WeatherKind.HeavyRain: l.Cloud = 0.95; l.Dim = 0.38; l.Rain = rain(0.6); l.LampBoost = 0.2; break;
            case WeatherKind.Thunder: l.Cloud = 1; l.Dim = 0.48; l.Rain = rain(0.6); l.LampBoost = 0.3; l.Lightning = true; break;
            case WeatherKind.Typhoon: l.Cloud = 1; l.Dim = 0.56; l.Rain = rain(0.75); l.LampBoost = 0.4; l.Lightning = WeatherKinds.thunderCodes.Contains(w.Code); break;
        }
        // 風：平均風與陣風混合；颱風級至少斜 1.4（約 55°）
        double eff = 0.6 * w.Wind + 0.4 * w.Gust;
        l.Tilt = Math.Min(1.8, eff / 14);
        if (l.Kind == WeatherKind.Typhoon) l.Tilt = Math.Max(1.4, l.Tilt);
        l.FallSpeed = 28 + 16 * l.Rain + (l.Kind == WeatherKind.Typhoon ? 10 : 0);
        return l;
    }
}

public static class SkyWeather
{
    /// 疊上天氣：天空往灰混、主光變弱變中性、環境光略壓暗、地面變暗（濕）、暗天氣城市燈提早亮。晴天回原值（像素不變）
    public static SkyLook weathered(this SkyLook self, WeatherLook w)
    {
        if (!(w.Cloud > 0 || w.Dim > 0)) return self;
        var s = self with { };
        double c = w.Cloud, d = w.Dim;
        static Vec3 mix(Vec3 a, Vec3 b, double f) => a + (b - a) * f;
        static double lum(Vec3 x) => x.X * 0.2126 + x.Y * 0.7152 + x.Z * 0.0722;
        var tint = new Vec3(0.95, 0.98, 1.03);           // 雨天的灰略偏冷
        var hor = Vec3.Repeating(lum(self.Horizon)) * tint * (1 - 0.55 * d);
        s.Horizon = mix(self.Horizon, hor, c);
        s.Zenith = mix(self.Zenith, hor * 0.9, c);       // 陰天整片天幾乎一樣灰，天頂稍暗
        s.GlowAmount = self.GlowAmount * (1 - c);
        s.Ground = mix(self.Ground, self.Ground * (1 - 0.45 * d), c);
        s.KeyIntensity = self.KeyIntensity * (1 - 0.7 * c);
        s.KeyColor = mix(self.KeyColor, SkyLook.hex(0xE4E8EE), c);
        s.AmbientIntensity = self.AmbientIntensity * (1 + 0.15 * c) * Math.Max(0.35, 1 - 1.1 * d);
        s.AmbientColor = mix(self.AmbientColor, SkyLook.hex(0xC8D0DA), c * 0.7);
        s.Fill = self.Fill * (1 - 0.4 * c) * Math.Max(0.2, 1 - 1.2 * d);
        s.MoonFill = self.MoonFill * (1 - 0.5 * c);
        if (self.Dark < 0.45) s.Dark = Math.Min(0.45, self.Dark + 0.9 * d);     // 白天變暗但不會被當成夜晚（isNight 是 ≥ 0.5）
        s.Lamps = Math.Max(self.Lamps, w.LampBoost);
        s.Overcast = c;
        return s;
    }
}
