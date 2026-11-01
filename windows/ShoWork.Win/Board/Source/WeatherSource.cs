using System.Net.Http;

namespace ShoWork;

// Mac 版 Sources/ShoWorkAgent/OfficeWeather.swift 的 Windows 轉寫（11-02 P8）。
/// 真實天氣（10-21，規範 §3.8.2）：Open-Meteo 每 10 分鐘抓一次清單裡的地點（HttpClient 背景、絕不卡 UI 執行緒），
/// 每地各自失敗保留上次結果。畫面（雲、雨、颱風）只跟主天氣＝清單的第一個。地點預設只有台北。
/// 失敗（離線、Open-Meteo 掛了）：有舊資料就留著；從來沒抓到過＝nil（當晴天）。不另外重試，等下一輪 10 分鐘（不會重試風暴）。
/// 測試視窗不連網：SHOWORK_OFFICE_WEATHER=clear|cloudy|overcast|rain|heavy|storm|typhoon 強制天氣（逗號分隔＝依序給清單的地點），
/// 不設＝晴天；=live 才真的連網抓。
/// 跟 Mac 不同：地點清單存在 %LOCALAPPDATA%\ShoWork42\office-weather.json（Mac 是 UserDefaults office.weatherPlaces）；
///   開關檔 office-weather-off 存在＝關（Mac：燈光選單「真實天氣」）。地名搜尋（Geocode）的 UI 還沒做，Geocode.parse 有轉寫。
public sealed class OfficeWeather
{
    public static readonly TimeSpan interval = TimeSpan.FromMinutes(10);
    static string placesPath => Path.Combine(Wire.SupportDir, "office-weather.json");
    static string offPath => Path.Combine(Wire.SupportDir, "office-weather-off");

    public sealed record Report(WeatherNow Now, DateTime At);      // 最近一次成功抓到的觀測＋時間

    readonly object gate = new();
    readonly Dictionary<WeatherSite, Report> reports = new();
    readonly HashSet<WeatherSite> inFlight = new();
    readonly HashSet<WeatherSite> failed = new();
    readonly bool live;
    DateTime lastFetch = DateTime.MinValue;
    static readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(20) };

    public List<WeatherSite> sites { get; }
    public bool enabled { get; }
    public WeatherSite main => sites.FirstOrDefault() ?? WeatherSite.taipei;
    /// 抓到新資料（背景執行緒叫）
    public event Action? Changed;

    public OfficeWeather(bool testMode)
    {
        var testValue = Environment.GetEnvironmentVariable("SHOWORK_OFFICE_WEATHER");
        live = !testMode || testValue == "live";
        enabled = testMode || !File.Exists(offPath);
        if (testMode)
        {
            var names = Environment.GetEnvironmentVariable("SHOWORK_OFFICE_WEATHER_SITES")?.Split(',') ?? Array.Empty<string>();
            var xs = names.Select(n => WeatherSite.presets.GetValueOrDefault(n)).OfType<WeatherSite>().ToList();
            sites = xs.Count == 0 ? WeatherSite.defaults : xs;
        }
        else
        {
            string? data = null;
            try { if (File.Exists(placesPath)) data = File.ReadAllText(placesPath); } catch { }
            sites = WeatherSite.load(data);
        }
        if (testValue == "fail") foreach (var s in sites) failed.Add(s);
        if (!live && testValue?.Split(',') is { Length: > 0 } ns && ns[0].Length > 0)
        {
            var t = DateTime.UtcNow;
            for (int i = 0; i < sites.Count; i++)
                if (WeatherKinds.preset(ns[Math.Min(i, ns.Length - 1)]) is { } w) reports[sites[i]] = new Report(w, t);
        }
    }

    /// 畫面用的天氣＝主天氣（關掉＝nil＝晴天）
    public WeatherNow? current { get { lock (gate) return enabled && reports.TryGetValue(main, out var r) ? r.Now : null; } }
    public WeatherLook look => WeatherLook.of(current);
    public Report? report(WeatherSite s) { lock (gate) return enabled && reports.TryGetValue(s, out var r) ? r : null; }

    /// 看板 refresh 叫：到時間了才抓（Mac 是自己的 10 分鐘 Timer；這裡掛在既有的刷新上，不另開）
    public void tick()
    {
        if (!enabled || !live) return;
        var now = DateTime.UtcNow;
        if (now - lastFetch < interval) return;
        lastFetch = now;
        fetch();
    }

    void fetch()
    {
        foreach (var site in sites)
        {
            lock (gate) { if (!inFlight.Add(site)) continue; }
            _ = Task.Run(async () =>
            {
                WeatherNow? w = null;
                try
                {
                    using var req = new HttpRequestMessage(HttpMethod.Get, OpenMeteo.url(site));
                    req.Headers.UserAgent.ParseAdd("ShoWork42");
                    using var resp = await http.SendAsync(req);
                    if (resp.IsSuccessStatusCode) w = OpenMeteo.parse(await resp.Content.ReadAsStringAsync());      // 背景執行緒解析
                }
                catch { }
                bool changed = false;
                lock (gate)
                {
                    inFlight.Remove(site);
                    if (w != null) { changed = !reports.TryGetValue(site, out var old) || old.Now != w; reports[site] = new Report(w, DateTime.UtcNow); failed.Remove(site); }   // 失敗：保留上次（更新時間也不動）
                    else if (!reports.ContainsKey(site) && sites.Contains(site)) failed.Add(site);
                }
                if (changed) Changed?.Invoke();
            });
        }
    }

    /// 同步抓一次主天氣（--city-dump 用）
    public WeatherNow? fetchNow()
    {
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, OpenMeteo.url(main));
            req.Headers.UserAgent.ParseAdd("ShoWork42");
            using var resp = http.Send(req);
            if (!resp.IsSuccessStatusCode) return null;
            using var sr = new StreamReader(resp.Content.ReadAsStream());
            var w = OpenMeteo.parse(sr.ReadToEnd());
            if (w != null) lock (gate) reports[main] = new Report(w, DateTime.UtcNow);
            return w;
        }
        catch { return null; }
    }
}
