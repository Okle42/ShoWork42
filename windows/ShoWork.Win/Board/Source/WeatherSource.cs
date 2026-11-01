using System.Net.Http;

namespace ShoWork;

// Mac 版 Sources/ShoWorkAgent/OfficeWeather.swift 的 Windows 轉寫（11-02 P8）。
/// 真實天氣（10-21，規範 §3.8.2）：Open-Meteo 每 10 分鐘抓一次清單裡的地點（HttpClient 背景、絕不卡 UI 執行緒），
/// 每地各自失敗保留上次結果。畫面（雲、雨、颱風）只跟主天氣＝清單的第一個。地點預設只有台北。
/// 失敗（離線、Open-Meteo 掛了）：有舊資料就留著；從來沒抓到過＝nil（當晴天）。不另外重試，等下一輪 10 分鐘（不會重試風暴）。
/// 測試視窗不連網：SHOWORK_OFFICE_WEATHER=clear|cloudy|overcast|rain|heavy|storm|typhoon 強制天氣（逗號分隔＝依序給清單的地點），
/// 不設＝晴天；=live 才真的連網抓。
/// 跟 Mac 不同：地點清單存在 %LOCALAPPDATA%\ShoWork42\office-weather.json（Mac 是 UserDefaults office.weatherPlaces）；
///   開關檔 office-weather-off 存在＝關（Mac：燈光選單「真實天氣」）。地名搜尋與地點清單由網頁的天氣面板改（setPref／weatherSearch）。
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

    public List<WeatherSite> sites { get; private set; }
    public bool enabled { get; private set; }
    readonly bool testMode;
    public WeatherSite main => sites.FirstOrDefault() ?? WeatherSite.taipei;
    /// 抓到新資料（背景執行緒叫）
    public event Action? Changed;

    public OfficeWeather(bool testMode)
    {
        var testValue = Environment.GetEnvironmentVariable("SHOWORK_OFFICE_WEATHER");
        this.testMode = testMode;
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

    // MARK: 11-02 P8 第二輪：網頁的天氣地點面板（Mac：OfficeWeather.enabled／sites 的 didSet、search、menuStatus）

    /// 燈光選單「真實天氣」開關（測試視窗不寫檔）
    public void setEnabled(bool on)
    {
        if (on == enabled) return;
        enabled = on;
        if (!testMode)
            try { if (on) File.Delete(offPath); else { Directory.CreateDirectory(Path.GetDirectoryName(offPath)!); File.WriteAllText(offPath, ""); } } catch { }
        if (on && live) { lastFetch = DateTime.MinValue; tick(); }
        Changed?.Invoke();
    }

    /// 地點清單（第一個是主天氣）；新加的地點馬上抓一次
    public void setSites(List<WeatherSite> xs)
    {
        var list = xs.Where(x => x.Title.Length > 0).Take(WeatherSite.limit).ToList();
        if (list.Count == 0) list = WeatherSite.defaults;
        lock (gate)
        {
            if (list.Count == sites.Count && list.Zip(sites).All(p => p.First == p.Second)) return;
            sites = list;
            foreach (var k in reports.Keys.Where(k => !list.Contains(k)).ToList()) reports.Remove(k);
            failed.IntersectWith(list);
        }
        if (!testMode) try { Directory.CreateDirectory(Path.GetDirectoryName(placesPath)!); File.WriteAllText(placesPath, WeatherSite.save(list)); } catch { }
        if (enabled && live) fetch();
        Changed?.Invoke();
    }

    /// 天氣列每個地點：[{ site, report: {now, at} | null, failed }]
    public System.Text.Json.Nodes.JsonArray sitesJson()
    {
        var a = new System.Text.Json.Nodes.JsonArray();
        lock (gate)
            foreach (var s in sites)
            {
                var r = enabled && reports.TryGetValue(s, out var x) ? x : null;
                a.Add(new System.Text.Json.Nodes.JsonObject
                {
                    ["site"] = MacMirror.Encode(s),
                    ["report"] = r == null ? null : new System.Text.Json.Nodes.JsonObject { ["now"] = MacMirror.Encode(r.Now), ["at"] = MacMirror.Encode(r.At) },
                    ["failed"] = failed.Contains(s),
                });
            }
        return a;
    }

    /// 選單裡的狀態
    public string menuStatus
    {
        get
        {
            if (!enabled) return "真實天氣：關";
            lock (gate)
            {
                if (!live) return reports.Count == 0 ? "測試視窗不連網（晴）" : "測試：假天氣";
                return reports.TryGetValue(main, out var r) ? r.Now.summary(main) : $"{main.Title}天氣：讀取中（先當晴天）";
            }
        }
    }

    /// 地名搜尋（打字就叫：停 300 毫秒才真的查，新的一筆取消舊的；測試視窗不連網）。結果用 done 回（背景執行緒）
    int searchSeq;
    public void search(string q, Action<List<WeatherSite>, string?> done)
    {
        int me = Interlocked.Increment(ref searchSeq);
        if (Geocode.url(q) is not { } url) { done(new(), q.Trim().Length == 0 ? null : "至少打 2 個字"); return; }
        if (!live)
        {
            var xs = WeatherSite.presets.Values.Where(s => s.Title.Contains(q)).ToList();
            done(xs, xs.Count == 0 ? "測試視窗不連網" : null);
            return;
        }
        _ = Task.Run(async () =>
        {
            await Task.Delay(300);
            if (me != searchSeq) return;
            List<WeatherSite> rs = new(); string? note;
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Get, url);
                req.Headers.UserAgent.ParseAdd("ShoWork42");
                using var resp = await http.SendAsync(req);
                if (resp.IsSuccessStatusCode) { rs = Geocode.parse(await resp.Content.ReadAsStringAsync()); note = rs.Count == 0 ? "找不到這個地方" : null; }
                else note = "搜尋失敗（離線或服務沒回應），等一下再試";
            }
            catch { note = "搜尋失敗（離線或服務沒回應），等一下再試"; }
            if (me != searchSeq) return;
            done(rs, note);
        });
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
