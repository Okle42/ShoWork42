namespace ShoWork;

// Mac 版 Sources/ShoWorkCore/Solar.swift 的逐行轉寫（11-02 P8）。
// 太陽位置（10-21：3D 科技大樓的日出日落）。NOAA Solar Calculator 的公式（https://gml.noaa.gov/grad/solcalc/calcdetails.html），
// 純函式、本機算、不連網。預設地點台北（北緯 25.03、東經 121.56）。精度：日出日落 ±1 分鐘級，夠畫面用。

public sealed record SunSample
{
    /// 太陽仰角（度，含大氣折射；地平線 0、負的在地平線下）
    public double Elevation { get; set; }
    /// 方位角（度，北 0、東 90、南 180、西 270）
    public double Azimuth { get; set; }
    /// 上午（太陽還在往上爬）：清晨與傍晚的配色不同
    public bool Rising { get; set; }
    public SunSample(double elevation, double azimuth, bool rising) { Elevation = elevation; Azimuth = azimuth; Rising = rising; }
}

public static class Solar
{
    public static readonly (double lat, double lon) taipei = (25.03, 121.56);

    static double rad(double d) => d * Math.PI / 180;
    static double deg(double r) => r * 180 / Math.PI;
    /// Swift truncatingRemainder＝C# 的 %（符號跟被除數）
    static double trem(double a, double b) => a % b;

    /// 某個瞬間的赤緯（度）與均時差（分鐘）
    static (double decl, double eqTime) declinationAndEqTime(DateTime date)
    {
        double jd = MacMirror.Seconds(date) / 86400 + 2440587.5;
        double jc = (jd - 2451545) / 36525;
        double l0 = trem(280.46646 + jc * (36000.76983 + jc * 0.0003032), 360);
        double m = 357.52911 + jc * (35999.05029 - 0.0001537 * jc);
        double e = 0.016708634 - jc * (0.000042037 + 0.0000001267 * jc);
        double c = Math.Sin(rad(m)) * (1.914602 - jc * (0.004817 + 0.000014 * jc)) + Math.Sin(rad(2 * m)) * (0.019993 - 0.000101 * jc)
                   + Math.Sin(rad(3 * m)) * 0.000289;
        double trueLong = l0 + c;
        double omega = 125.04 - 1934.136 * jc;
        double appLong = trueLong - 0.00569 - 0.00478 * Math.Sin(rad(omega));
        double meanObliq = 23 + (26 + (21.448 - jc * (46.815 + jc * (0.00059 - jc * 0.001813))) / 60) / 60;
        double obliq = meanObliq + 0.00256 * Math.Cos(rad(omega));
        double decl = deg(Math.Asin(Math.Sin(rad(obliq)) * Math.Sin(rad(appLong))));
        double y = Math.Pow(Math.Tan(rad(obliq / 2)), 2);
        double eq = 4 * deg(y * Math.Sin(2 * rad(l0)) - 2 * e * Math.Sin(rad(m)) + 4 * e * y * Math.Sin(rad(m)) * Math.Cos(2 * rad(l0))
                            - 0.5 * y * y * Math.Sin(4 * rad(l0)) - 1.25 * e * e * Math.Sin(2 * rad(m)));
        return (decl, eq);
    }

    /// 太陽仰角＋方位角（NOAA，含大氣折射修正）
    public static SunSample position(DateTime date, double lat = 25.03, double lon = 121.56)
    {
        var (decl, eqTime) = declinationAndEqTime(date);
        double utcMin = trem(MacMirror.Seconds(date), 86400) / 60;
        double tst = trem(utcMin + eqTime + 4 * lon, 1440);
        if (tst < 0) tst += 1440;
        double ha = tst / 4 < 0 ? tst / 4 + 180 : tst / 4 - 180;          // 時角（度）：正午 0、下午正
        double cz = Math.Sin(rad(lat)) * Math.Sin(rad(decl)) + Math.Cos(rad(lat)) * Math.Cos(rad(decl)) * Math.Cos(rad(ha));
        double zenith = deg(Math.Acos(Math.Min(1, Math.Max(-1, cz))));
        double el = 90 - zenith;
        // 大氣折射（NOAA 近似式）
        double refr;
        if (el > 85) refr = 0;
        else
        {
            double te = Math.Tan(rad(el));
            if (el > 5) refr = 58.1 / te - 0.07 / Math.Pow(te, 3) + 0.000086 / Math.Pow(te, 5);
            else if (el > -0.575) refr = 1735 + el * (-518.2 + el * (103.4 + el * (-12.79 + el * 0.711)));
            else refr = -20.772 / te;
        }
        double azDen = Math.Cos(rad(lat)) * Math.Sin(rad(zenith));
        double az;
        if (Math.Abs(azDen) < 1e-9) az = lat > 0 ? 180 : 0;
        else
        {
            double a = (Math.Sin(rad(lat)) * Math.Cos(rad(zenith)) - Math.Sin(rad(decl))) / azDen;
            double b = deg(Math.Acos(Math.Min(1, Math.Max(-1, a))));
            az = ha > 0 ? trem(b + 180, 360) : trem(540 - b, 360);
        }
        return new SunSample(el + refr / 3600, az, ha < 0);
    }

    /// 這一天（timeZone 的時區）的日出、日落時間（太陽上緣碰地平線，天頂角 90.833°）；極區沒有日出日落回 nil
    public static (DateTime sunrise, DateTime sunset, DateTime noon)? sunTimes(DateTime date, TimeZoneInfo? timeZone = null, double lat = 25.03, double lon = 121.56)
    {
        var tz = timeZone ?? TimeZoneInfo.Local;
        var local = TimeZoneInfo.ConvertTimeFromUtc(DateTime.SpecifyKind(date.Kind == DateTimeKind.Local ? date.ToUniversalTime() : date, DateTimeKind.Utc), tz);
        var localNoon = TimeZoneInfo.ConvertTimeToUtc(new DateTime(local.Year, local.Month, local.Day, 12, 0, 0, DateTimeKind.Unspecified), tz);
        // 當地正午那一刻的 UTC 日期（午夜）；事件時間＝這個午夜＋UTC 分鐘（可以是負的＝前一個 UTC 日）
        double day = Math.Floor(MacMirror.Seconds(localNoon) / 86400) * 86400;
        DateTime? solve(DateTime guess, double sign)
        {
            var t = guess;
            for (int i = 0; i < 3; i++)          // 用上一次的時間重算赤緯與均時差（收斂到秒級）
            {
                var (decl, eq) = declinationAndEqTime(t);
                double cosH = Math.Cos(rad(90.833)) / (Math.Cos(rad(lat)) * Math.Cos(rad(decl))) - Math.Tan(rad(lat)) * Math.Tan(rad(decl));
                if (!(sign == 0 || Math.Abs(cosH) <= 1)) return null;
                double h = sign == 0 ? 0 : deg(Math.Acos(cosH));
                double utcMin = 720 - 4 * (lon + sign * h) - eq;
                t = MacMirror.FromSeconds(day + utcMin * 60);
            }
            return t;
        }
        if (solve(localNoon, 0) is not { } noon || solve(noon, 1) is not { } rise || solve(noon, -1) is not { } set) return null;
        return (rise, set, noon);
    }
}

// MARK: - 天色（依太陽仰角連續混合）

/// 一個時間點的天色與燈光參數（顏色是 sRGB 0–1）。夜晚端、白天端跟改版前的二分燈光完全一樣（規範 §3.8／§3.8.1）
public sealed record SkyLook
{
    public Vec3 Horizon { get; set; }
    public Vec3 Zenith { get; set; }
    /// 太陽那一側地平線的光暈（日出日落）：顏色與強度 0–1
    public Vec3 Glow { get; set; }
    public double GlowAmount { get; set; }
    public Vec3 Ground { get; set; }
    /// 主光（白天＝太陽，夜晚＝月光，同一盞）
    public Vec3 KeyColor { get; set; }
    public double KeyIntensity { get; set; }
    public Vec3 AmbientColor { get; set; }
    public double AmbientIntensity { get; set; }
    /// 室內暖補光、夜晚戶外月光補光
    public double Fill { get; set; }
    public double MoonFill { get; set; }
    /// 暗度：日夜兩套底色、門牌乘色、vignetting 依這個混合（0＝白天、1＝夜晚）
    public double Dark { get; set; }
    /// 燈：窗光、路燈、城市燈光、吊燈 omni、bloom（黃昏逐漸點亮、清晨逐漸熄滅）
    public double Lamps { get; set; }
    /// 主光方向：nil＝美術固定角度（白天固定、夜晚月光）；有值＝真實太陽（仰角已夾在 ≥3°，方位角北 0 順時針）
    [MacName("sunDir")] public SunDir? SunDirection { get; set; }
    /// 雲量造成的「沒有直射陽光」0–1（10-21 天氣，Weather）：靜態假影子依這個淡掉；晴天 0
    public double Overcast { get; set; }

    public sealed record SunDir(double Elevation, double Azimuth)
    {
        public double Elevation { get; set; } = Elevation;
        public double Azimuth { get; set; } = Azimuth;
    }

    public static Vec3 hex(uint h) => new Vec3((h >> 16) & 255, (h >> 8) & 255, h & 255) / 255;

    static SkyLook Make(Vec3 horizon, Vec3 zenith, Vec3 glow, double glowAmount, Vec3 ground, Vec3 keyColor, double keyIntensity,
                        Vec3 ambientColor, double ambientIntensity, double fill, double moonFill, double dark, double lamps, SunDir? sunDir) => new()
    {
        Horizon = horizon, Zenith = zenith, Glow = glow, GlowAmount = glowAmount, Ground = ground, KeyColor = keyColor, KeyIntensity = keyIntensity,
        AmbientColor = ambientColor, AmbientIntensity = ambientIntensity, Fill = fill, MoonFill = moonFill, Dark = dark, Lamps = lamps, SunDirection = sunDir,
    };

    /// 改版前的白天（OfficeBuilder.applyLights 的白天值）
    public static SkyLook day => Make(hex(0xD3DCE2), hex(0xA9BCCB), hex(0xFFB070), 0, hex(0xA4ABB0), hex(0xFFEBD2), 600, hex(0xDCE6F0), 660, 340, 0, 0, 0, null);
    /// 改版前的夜晚
    public static SkyLook night => Make(hex(0x141B26), hex(0x070A10), hex(0x6A4A78), 0, hex(0x0D1218), hex(0xA9B8DE), 460, hex(0x8E9CC4), 260, 0, 1500, 1, 1, null);

    public bool isNight => Dark >= 0.5;

    /// 一個關鍵格：仰角 e 時的值（主光：太陽在 e ≥ −4° 時、月光在 e < −4° 時；換方向那一格強度是 0，不會跳）
    readonly record struct Key(double e, uint hor, uint zen, uint glow, double glowA, uint ground, uint key, double keyI, uint amb, double ambI,
                               double fill, double moon, double dark, double lamps);

    // 清晨：夜 →（−12～−6 天空漸亮、偏藍紫）→ 日出（−6～+6 地平線暖橘粉、主光低角度橘紅）→ 上午 → 白天
    static readonly Key[] morning =
    {
        new(-12, 0x141B26, 0x070A10, 0x3A3060, 0, 0x0D1218, 0xA9B8DE, 460, 0x8E9CC4, 260, 0, 1500, 1, 1),
        new(-9, 0x252A44, 0x0C1020, 0x4A3C70, 0.35, 0x111724, 0xA9B8DE, 330, 0x8E9CC6, 290, 0, 1250, 0.95, 1),
        new(-6, 0x4A4670, 0x18223E, 0x8A6A9A, 0.5, 0x1A2030, 0xA9B8DE, 160, 0x9298C8, 340, 40, 800, 0.82, 0.92),
        new(-4, 0x7A6A8E, 0x283652, 0xC8889A, 0.6, 0x363A52, 0xFF9A70, 0, 0xA6A0C8, 420, 80, 450, 0.68, 0.78),
        new(-1.5, 0xC08890, 0x46587A, 0xF4A07C, 0.8, 0x606278, 0xFF8A5A, 220, 0xBCAEC6, 490, 150, 120, 0.48, 0.5),
        new(1, 0xE6A088, 0x6A82A6, 0xFFA868, 0.9, 0x80828C, 0xFF9C5E, 420, 0xCABCC8, 555, 210, 0, 0.3, 0.22),
        new(4, 0xEAB898, 0x86A0BE, 0xFFBC80, 0.7, 0x8A8E90, 0xFFB27A, 520, 0xD2CCD2, 580, 270, 0, 0.14, 0.04),
        new(8, 0xDECCBC, 0x98B0C4, 0xFFD0A0, 0.4, 0x9A9FA2, 0xFFCDA0, 570, 0xD8DCE2, 630, 310, 0, 0.04, 0),
        new(15, 0xD6D8DA, 0xA4BAC9, 0xFFE0C0, 0.12, 0xA2A9AE, 0xFFE2C4, 595, 0xDAE4EE, 655, 335, 0, 0, 0),
        new(22, 0xD3DCE2, 0xA9BCCB, 0xFFB070, 0, 0xA4ABB0, 0xFFEBD2, 600, 0xDCE6F0, 660, 340, 0, 0, 0),
    };
    // 傍晚：白天 → 金黃時段（+10～0）→ 日落（0～−6 橘紅轉紫）→ 夜
    static readonly Key[] evening =
    {
        new(-12, 0x141B26, 0x070A10, 0x3A2A50, 0, 0x0D1218, 0xA9B8DE, 460, 0x8E9CC4, 260, 0, 1500, 1, 1),
        new(-9, 0x2A2644, 0x0D1020, 0x5A3A6A, 0.4, 0x121624, 0xA9B8DE, 330, 0x8E9AC6, 290, 0, 1250, 0.95, 1),
        new(-6, 0x5A426E, 0x1C2242, 0xA05A78, 0.6, 0x1C1E2C, 0xA9B8DE, 160, 0x9894C4, 340, 40, 800, 0.82, 0.9),
        new(-4, 0x8E5A78, 0x2C3456, 0xD06A6A, 0.75, 0x3A3E56, 0xFF7A50, 0, 0xA098C0, 420, 80, 450, 0.68, 0.75),
        new(-1.5, 0xD07A6E, 0x4A5478, 0xF48058, 0.9, 0x66667C, 0xFF7448, 240, 0xB8A8C0, 500, 150, 120, 0.48, 0.45),
        new(1, 0xEC9466, 0x6C7EA0, 0xFF8C4A, 1, 0x84828A, 0xFF8648, 440, 0xD2B4AC, 560, 220, 0, 0.28, 0.22),
        new(4, 0xEEAE76, 0x88A0BC, 0xFFA458, 0.8, 0x8E8C8A, 0xFFA25C, 540, 0xD8C4B6, 580, 280, 0, 0.12, 0.06),
        new(10, 0xE4CCA8, 0x9CB2C4, 0xFFC27A, 0.45, 0x9EA2A2, 0xFFC890, 590, 0xDCD8D6, 635, 320, 0, 0.02, 0),
        new(16, 0xD8D8D6, 0xA6BAC9, 0xFFD8A8, 0.15, 0xA3AAAE, 0xFFE0BC, 598, 0xDBE3EC, 655, 336, 0, 0, 0),
        new(22, 0xD3DCE2, 0xA9BCCB, 0xFFB070, 0, 0xA4ABB0, 0xFFEBD2, 600, 0xDCE6F0, 660, 340, 0, 0, 0),
    };
    /// 主光從太陽換成月光的仰角（這一格強度是 0）
    public const double keySwitch = -4.0;

    /// 依太陽位置混合（仰角 ≥ 22° 就是白天、≤ −12° 就是夜晚，跟改版前一模一樣）
    public static SkyLook at(SunSample s)
    {
        var t = s.Rising ? morning : evening;
        double e = s.Elevation;
        if (e >= t[^1].e) { var d = day; d.SunDirection = new SunDir(Math.Max(3, e), s.Azimuth); return d; }
        if (e <= t[0].e) return night;
        int i = Array.FindIndex(t, k => k.e > e);
        Key a = t[i - 1], b = t[i];
        double f = (e - a.e) / (b.e - a.e);
        double mix(double x, double y) => x + (y - x) * f;
        Vec3 mixC(uint x, uint y) { var p = hex(x); var q = hex(y); return p + (q - p) * f; }
        return Make(mixC(a.hor, b.hor), mixC(a.zen, b.zen), mixC(a.glow, b.glow), mix(a.glowA, b.glowA),
                    mixC(a.ground, b.ground), e >= keySwitch ? mixC(a.key, b.key) : hex(0xA9B8DE), mix(a.keyI, b.keyI),
                    mixC(a.amb, b.amb), mix(a.ambI, b.ambI), mix(a.fill, b.fill), mix(a.moon, b.moon),
                    mix(a.dark, b.dark), mix(a.lamps, b.lamps),
                    e >= keySwitch ? new SunDir(Math.Max(3, e), s.Azimuth) : null);
    }

    /// 給「自動・xx」那個標籤看的時段名稱
    public static string phaseTitle(SunSample s)
    {
        double e = s.Elevation;
        if (e <= -12) return "夜晚";
        if (e < -4) return s.Rising ? "清晨" : "黃昏";
        if (s.Rising) return e < 6 ? "日出" : "白天";
        if (e < 1) return "日落";
        if (e < 15) return "傍晚";
        return "白天";
    }
}
