using System.Globalization;
using System.Text.Json.Nodes;
using ShoWork;
using Xunit;
using Xunit.Abstractions;

// 11-02 P8：C# 轉寫的大樓／城市核心，跟 Mac bench dump 出來的 Web/bench/mac-input.json 比結構與數值（時間欄位只比有沒有值）。
// 餵的是跟 Mac bench 一樣的示範資料：OfficeDemo.apply("all")＋示範大樓（TowerCache）＋CityMonitor.demoState()＋一艘出港的船。
public class Office2Tests
{
    readonly ITestOutputHelper log;
    public Office2Tests(ITestOutputHelper log) { this.log = log; }

    static string MacInputPath()
    {
        var d = new DirectoryInfo(AppContext.BaseDirectory);
        while (d != null && !File.Exists(Path.Combine(d.FullName, "ShoWork.Win", "Board", "Web", "bench", "mac-input.json"))) d = d.Parent;
        Assert.NotNull(d);
        return Path.Combine(d!.FullName, "ShoWork.Win", "Board", "Web", "bench", "mac-input.json");
    }

    /// 時間欄位：只比「有沒有值」（Mac 的 dump 是那一刻的 Date()）
    static readonly HashSet<string> TimeKeys = new()
    {
        "at", "decidedAt", "freeAt", "lastActivity", "checkedAt", "lastOnline", "lastSync", "fiveReset", "sevenReset", "start", "lastScan",
        "createdAt", "updatedAt", "now", "builtAt", "firstSeen", "lastSeen", "turn",
    };

    static void Diff(JsonNode? a, JsonNode? b, string path, List<string> out_)
    {
        if (out_.Count > 60) return;
        var key = path.Split('.', '[')[^1].TrimEnd(']');
        if (TimeKeys.Contains(key))
        {
            if ((a == null) != (b == null)) out_.Add($"{path}: 有無值不同 mac={a?.ToJsonString() ?? "null"} win={b?.ToJsonString() ?? "null"}");
            return;
        }
        switch (a)
        {
            case null:
                if (b != null) out_.Add($"{path}: mac=null win={b.ToJsonString()}");
                return;
            case JsonObject ao:
                if (b is not JsonObject bo) { out_.Add($"{path}: mac 是物件 win={b?.ToJsonString() ?? "null"}"); return; }
                foreach (var k in ao.Select(kv => kv.Key).Union(bo.Select(kv => kv.Key)))
                {
                    if (!ao.ContainsKey(k)) { out_.Add($"{path}.{k}: mac 沒有這個欄位"); continue; }
                    if (!bo.ContainsKey(k)) { out_.Add($"{path}.{k}: win 沒有這個欄位"); continue; }
                    Diff(ao[k], bo[k], $"{path}.{k}", out_);
                }
                return;
            case JsonArray aa:
                if (b is not JsonArray ba) { out_.Add($"{path}: mac 是陣列 win={b?.ToJsonString() ?? "null"}"); return; }
                if (aa.Count != ba.Count) out_.Add($"{path}: 長度 mac={aa.Count} win={ba.Count}");
                for (int i = 0; i < Math.Min(aa.Count, ba.Count); i++) Diff(aa[i], ba[i], $"{path}[{i}]", out_);
                return;
            case JsonValue av:
                if (b is not JsonValue bv) { out_.Add($"{path}: mac={av.ToJsonString()} win={b?.ToJsonString() ?? "null"}"); return; }
                if (av.TryGetValue<double>(out var x) && bv.TryGetValue<double>(out var y))
                {
                    if (Math.Abs(x - y) > 1e-6 * Math.Max(1, Math.Abs(x))) out_.Add($"{path}: mac={x} win={y}");
                    return;
                }
                if (av.ToJsonString() != bv.ToJsonString()) out_.Add($"{path}: mac={av.ToJsonString()} win={bv.ToJsonString()}");
                return;
        }
    }

    /// Mac 拿真實 session 當示範卡片的底（OfficeDemo.apply 的 base）：從 dump 裡的第一張卡還原那些沒被示範覆寫的欄位
    static BoardCard BaseCard(JsonObject card) => new()
    {
        Id = "base", SessionId = "base", Pid = (int)card["pid"]!.GetValue<double>(), Cwd = card["cwd"]?.ToString(), Kind = card["kind"]?.ToString(),
        Name = card["name"]?.ToString(), Project = "x", Title = "x", Reason = "x",
        LastActivity = card["lastActivity"] is JsonValue la ? MacMirror.FromSeconds(la.GetValue<double>()) : null,
        Ctx = card["ctx"] is JsonObject c ? new ContextUse { Percent = c["percent"]!.GetValue<double>(), Tokens = (int?)c["tokens"]?.GetValue<double>(),
                                                             At = c["at"] is JsonValue ca ? MacMirror.FromSeconds(ca.GetValue<double>()) : null } : null,
    };

    [Fact] // office2 跟 Mac bench 的 mac-input.json 一樣（tower、decor、wander、islands、guardStatus、scanning、city）
    public void MatchesMacBenchInput()
    {
        var mac = JsonNode.Parse(File.ReadAllText(MacInputPath()))!.AsObject();
        var now = MacMirror.FromSeconds(mac["now"]!.GetValue<double>());
        // Mac 的語系是 zh_TW（localizedStandardCompare：中文照筆畫、排在英文前面）：示範專案的樓層號照這個排
        var saved = ResidentProjects.Collation;
        ResidentProjects.Collation = CultureInfo.GetCultureInfo("zh-TW").CompareInfo;
        try
        {
            var first = mac["islands"]![0]!["people"]![0]!["card"]!.AsObject();
            var b = BaseCard(first);
            var cards = OfficeDemo.apply("all", new List<BoardCard> { b }, now, b);
            var deps = OfficeDemo.departments(new(), cards, "all");
            var (plan, decor, wander) = new OfficeDemo.TowerCache().make(deps, cards, new Dictionary<string, FloorDecor>(), now);
            var islands = Islands.Build(cards);
            var city = CityMonitor.demoState(now);
            city.Ships = new() { new CityShip("demo-app", now) };
            var win = Office2.Payload(plan, decor, wander, islands, new GuardStatus(), false, city, now);
            if (Environment.GetEnvironmentVariable("SHOWORK_DUMP_OFFICE2") is { Length: > 0 } dump) File.WriteAllText(dump, Office2.Json(win));
            var diffs = new List<string>();
            foreach (var k in new[] { "tower", "decor", "wander", "islands", "guardStatus", "scanning", "city" }) Diff(mac[k], win[k], k, diffs);
            foreach (var d in diffs) log.WriteLine(d);
            Assert.Empty(diffs);
            Assert.Equal("office2", win["type"]!.ToString());
        }
        finally { ResidentProjects.Collation = saved; }
    }

    [Fact] // 可重現的亂數：跟 Mac 同一個種子同一個數（示範的三個休息的人：一樓咖啡館、頂樓、頂樓）
    public void WanderRandMatchesMac()
    {
        var p = new[] { "demo-18", "demo-19", "demo-20" }.Select(s => Math.Min(2, (int)(WanderPlanner.rand(s, 0, "rest3") * 3))).ToArray();
        Assert.Equal(1, p[0]);              // 1＝咖啡館
        Assert.Equal(0, p[1]);              // 0＝頂樓
        Assert.Equal(0, p[2]);
    }

    [Fact] // 樓層號：第一次依 7 天用量排名；之後新專案接在最後、不重排；全部 AI 走了 2 小時內樓層留著（燈暗），之後降到閒置薄層
    public void TowerNumbersAndDemotion()
    {
        var t0 = new DateTime(2026, 11, 2, 2, 0, 0, DateTimeKind.Utc);
        BoardCard C(string id, string p) => new() { Id = id, SessionId = id, Project = p, Title = id, Reason = "工作中", Column = BoardColumn.Active };
        var reg = new TowerRegistry();
        var cards = new List<BoardCard> { C("a", "Alpha"), C("b", "Beta") };
        var (plan, dirty) = TowerPlan.build(OfficeDepartments.build(new[] { "Gamma" }, cards), cards, reg,
                                            () => new() { ["beta"] = 5, ["gamma"] = 1 }, null, t0);
        Assert.True(dirty);
        Assert.Equal(2, reg.number("Beta")); Assert.Equal(3, reg.number("Gamma")); Assert.Equal(4, reg.number("Alpha"));
        Assert.Equal(new[] { "lobby", "idle-0", "p:beta", "p:alpha", "roof" }, plan.Floors.Select(f => f.Id));
        Assert.Equal("03", plan.Floors[1].Plates.Single().FloorNo);
        // Alpha 的 AI 關掉：2 小時內樓層還在（臨時部門從名冊補回來，燈暗）
        var later = new List<BoardCard> { C("b", "Beta") };
        var (p1, _) = TowerPlan.build(OfficeDepartments.build(new[] { "Gamma" }, later), later, reg, () => new(), null, t0.AddMinutes(30));
        Assert.False(p1.floor("p:alpha")!.Active);
        var (p2, _) = TowerPlan.build(OfficeDepartments.build(new[] { "Gamma" }, later), later, reg, () => new(), null, t0.AddHours(3));
        Assert.Null(p2.floor("p:alpha"));
        // 回來了：號碼不變
        var (p3, _) = TowerPlan.build(OfficeDepartments.build(new[] { "Gamma" }, cards), cards, reg, () => new(), null, t0.AddHours(4));
        Assert.Equal("04", p3.floor("p:alpha")!.FloorNo);
        // 名冊存檔讀回一樣（Mac 格式：camelCase、日期 ISO 8601）
        var back = TowerRegistry.decode(reg.encoded());
        Assert.Equal(reg.Numbers, back.Numbers);
        Assert.Equal(reg.LastSeen["alpha"], back.LastSeen["alpha"]);
        Assert.Empty(TowerRegistry.decode("{壞掉").Numbers);
    }

    [Fact] // 主題：專案名＋README 身分；AI 的主題不在身分前 2 名就不採用、識別色鎖主題色
    public void ThemeSignature()
    {
        var s = WorkSignature.make(new DecorInput("PokerGame"));
        Assert.Equal(TowerTheme.game_lab, s.best.theme);
        Assert.Equal("Demo Line 42", WorkSignature.splitName("DemoLine42"));
        var ai = DecorPrompt.parse("```json\n{\"theme\":\"legal_room\",\"accentColor\":\"#000000\",\"props\":[\"law_shelf\",\"sofa\",\"不存在\"],\"reason\":\"測試\"}\n```",
                                   s, "haiku", 0.001, DateTime.UtcNow)!;
        Assert.Equal("#4A5A7A", ai.AccentColor);
        Assert.Equal(new[] { "law_shelf", "sofa" }, ai.Props);
        var r = DecorPolicy.reconcile(ai, s);
        Assert.Equal(TowerTheme.game_lab, r.Theme);           // 身分很明確（專案名 poker＋game ×2）⇒ 換回身分主題
        Assert.Equal(TowerTheme.game_lab.accent(), r.AccentColor);
        // 快取檔讀回一樣
        var back = FloorDecor.decode(r.encoded())!;
        Assert.Equal(r.Theme, back.Theme); Assert.Equal(r.Props, back.Props);
    }

    [Fact] // 城市：Windows 的 netsh／netstat 解析；ssh config；貨櫃
    public void CityParsing()
    {
        var zh = "\r\n網域設定檔 設定:\r\n----------------------------------------------------------------------\r\n狀態                                  開啟\r\n\r\n私人設定檔 設定:\r\n----------------------------------------------------------------------\r\n狀態                                  開啟\r\n\r\n公用設定檔 設定:\r\n----------------------------------------------------------------------\r\n狀態                                  關閉\r\n確定。\r\n";
        Assert.Equal(3, CityParseWin.netshProfiles(zh).Count);
        Assert.False(CityParseWin.firewall(zh));
        var en = "\r\nDomain Profile Settings:\r\n----------------------------------------------------------------------\r\nState                                 ON\r\n\r\nPrivate Profile Settings:\r\n----------------------------------------------------------------------\r\nState                                 ON\r\n\r\nPublic Profile Settings:\r\n----------------------------------------------------------------------\r\nState                                 ON\r\nOk.\r\n";
        Assert.True(CityParseWin.firewall(en));
        Assert.Null(CityParseWin.firewall("找不到"));
        var ns = "\r\n使用中連線\r\n\r\n  協定   本機位址               外部位址               狀態           PID\r\n  TCP    0.0.0.0:135            0.0.0.0:0              LISTENING       1140\r\n  TCP    127.0.0.1:4242         0.0.0.0:0              LISTENING       77\r\n  TCP    192.168.1.5:139        0.0.0.0:0              LISTENING       4\r\n  TCP    192.168.1.5:50000      20.1.1.1:443           ESTABLISHED     900\r\n  TCP    [::]:9888              [::]:0                 LISTENING       55\r\n  TCP    [::1]:4242             [::]:0                 LISTENING       77\r\n";
        var ports = CityParseWin.netstat(ns, pid => pid == 77 ? "demo" : null);
        Assert.Equal(new[] { 135, 139, 4242, 9888 }, ports.Select(p => p.Port));
        Assert.False(ports.Single(p => p.Port == 4242).External);
        Assert.Equal("demo", ports.Single(p => p.Port == 4242).Process);
        Assert.True(ports.Single(p => p.Port == 9888).openRed);
        Assert.Equal("pid 1140", ports[0].Process);
        var hosts = CityParse.sshHosts("Host winlap\n  HostName 192.0.2.5\n  Port 2222\nHost *\n  User x\nHost a b\nHostName=h.local\n");
        Assert.Equal(new[] { "winlap", "a", "b" }, hosts.Select(h => h.Alias));
        Assert.Equal(2222, hosts[0].Port); Assert.Equal("h.local", hosts[2].HostName);
        Assert.Equal((0, 0, 0), CityRules.containers(0));
        Assert.Equal((48, 4, 6), CityRules.containers(1.0));
        Assert.Equal("Google Drive", CityParse.cloudName("GoogleDrive-a@b.com"));
    }

    [Fact] // 太陽：台北 11-02 正午太陽在南方、午夜在地平線下；天色混合的兩端＝改版前的日夜
    public void SolarAndSky()
    {
        var noon = new DateTime(2026, 11, 2, 4, 0, 0, DateTimeKind.Utc);      // 台北 12:00
        var s = Solar.position(noon);
        Assert.InRange(s.Elevation, 40, 55); Assert.InRange(s.Azimuth, 150, 210);
        Assert.True(Solar.position(noon.AddHours(12)).Elevation < -40);
        Assert.False(SkyLook.at(s).isNight);
        Assert.True(SkyLook.at(Solar.position(noon.AddHours(12))).isNight);
        var w = WeatherLook.of(WeatherKinds.preset("typhoon"));
        Assert.Equal(WeatherKind.Typhoon, w.Kind);
        Assert.True(w.Tilt >= 1.4);
        Assert.Equal(WeatherKind.HeavyRain, WeatherKinds.classify(OpenMeteo.parse("""{"current":{"interval":900,"weather_code":61,"precipitation":2.5,"cloud_cover":100,"wind_speed_10m":3,"wind_gusts_10m":5}}""")!));
    }
}
