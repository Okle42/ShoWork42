namespace ShoWork;

// Mac 版 Sources/ShoWorkCore/Poof.swift 的逐行轉寫（11-02 P8）。畫面在網頁（JS 那邊照同一套數字）；C# 這份給測試、以後比對用。
/// 忍術「ドロン」過場（10-21）：角色離開／出現時爆出一團體素煙霧。
/// 這裡只放「第 t 秒長什麼樣」的純函式（測試、定格截圖、動畫每幀都呼叫同一套）。
///   離開：0–0.05 秒煙冒出 → 角色在煙最濃時（0.05–0.14 秒）縮到 0 → 煙往外、往上擴散放大、淡出，0.8 秒散完
///   出現：先冒煙 → 0.12 秒角色從煙裡彈出來（0.3 秒放大到 1.15 倍、0.45 秒回到 1）→ 煙散掉
public static class PoofCurve
{
    public const double duration = 0.8;
    public const int puffs = 10;

    public readonly record struct Puff(Vec3 Offset, double Scale, double Opacity, double Spin);   // offset＝相對煙霧中心（公尺）；spin＝繞 Y 軸（弧度）

    static double clamp01(double x) => Math.Min(1, Math.Max(0, x));
    static double easeOut(double x) { double k = clamp01(x); return 1 - (1 - k) * (1 - k) * (1 - k); }

    /// 第 i 顆煙的方向（固定，不用亂數：每次長一樣，截圖可比）：繞一圈平均分布、高低交錯、略往上
    static Vec3 direction(int i, int n)
    {
        double a = (double)i / n * 2 * Math.PI + 0.3;
        double up = i % 2 == 0 ? 0.55 : 0.15;
        var v = new Vec3(Math.Cos(a), up, Math.Sin(a));
        return v / Math.Sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z);
    }

    /// 第 i 顆煙在第 t 秒：0.05 秒內冒到最濃（不透明、0.5→1 倍），之後往外飄 1 公尺、往上 0.35、放大到 1.6 倍，0.25 秒起淡出、0.8 秒歸零
    public static Puff puff(int i, double t, int n = puffs)
    {
        var d = direction(i, n);
        double k = clamp01(t / duration);
        double burst = easeOut(t / 0.18);                       // 前 0.18 秒衝出去最快
        double dist = 0.55 * burst + 0.45 * easeOut(k);        // 角色身體約 1 公尺寬：一冒出來就要在身體外圍
        double rise = 0.35 * k;                                 // 不要往上穿過天花板到上一層
        double grow = t < 0.05 ? 0.5 + 0.5 * (t / 0.05) : 1 + 0.6 * easeOut((t - 0.05) / (duration - 0.05));
        double fadeIn = clamp01(t / 0.04);
        double fadeOut = t <= 0.25 ? 1 : 1 - clamp01((t - 0.25) / (duration - 0.25 - 0.02));
        double size = 0.75 + 0.25 * ((i * 5) % 3) / 2.0;        // 大小交錯
        return new Puff(new Vec3(d.X * dist, d.Y * dist + rise, d.Z * dist), Math.Max(0, grow * size), t >= duration ? 0 : fadeIn * fadeOut,
                        i * 0.7 + (i % 2 == 0 ? 1 : -1) * 2.4 * k);
    }

    /// 角色的大小：離開＝0.05 秒前原尺寸、0.14 秒縮到 0（帶一點轉）；出現＝0.12 秒前 0、0.3 秒 1.15 倍、0.45 秒回 1
    public static (double scale, double spin) person(double t, bool appear)
    {
        if (appear)
        {
            if (t < 0.12) return (0, 0);
            if (t < 0.3) { double k = easeOut((t - 0.12) / 0.18); return (1.15 * k, 0.6 * (1 - k)); }
            if (t < 0.45) { double k = clamp01((t - 0.3) / 0.15); return (1.15 - 0.15 * k * k * (3 - 2 * k), 0); }
            return (1, 0);
        }
        if (t < 0.05) return (1, 0);
        if (t < 0.14) { double k = clamp01((t - 0.05) / 0.09); return (1 - k * k, 1.2 * k); }
        return (0, 1.2);
    }
}
