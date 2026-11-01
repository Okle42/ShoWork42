using System.Text.Json.Nodes;

namespace ShoWork;

// office2：Windows 推給 3D 網頁（Board\Web，three.js）的資料（11-02 P8）。形狀跟 Mac bench dump 出來的 Web/bench/mac-input.json 一樣
// （SceneDump.input：tower、decor、wander、islands、guardStatus、scanning、city），網頁的 JS 照那個形狀寫；外加 Windows 這邊算好的
// lighting／look／night（天色）、weather（主天氣）、graph（地下室神經網路）。全部用 MacMirror 編碼（Swift Mirror 的規則）。
// 也放 Mac OfficeView.swift 的 OfficeDemo（示範卡片「all」＋示範大樓 TowerCache）與 TowerSource.swift 的 TowerStore.people（純函式）。
// 這個檔不碰 WinForms（測試專案直接連）。

/// BoardCard 的 Mirror：欄位照 Mac 的 BoardCard（28 個）。Windows 沒有的欄位寫 Swift 的預設值（SelfReport 少的 7 個寫 null）
public static class CardMirror
{
    public static JsonObject Of(BoardCard c) => new()
    {
        ["id"] = c.Id, ["column"] = MacMirror.Camel(c.Column.ToString()), ["reason"] = c.Reason, ["project"] = c.Project, ["title"] = c.Title,
        ["detail"] = c.Detail, ["lastActivity"] = MacMirror.Encode(c.LastActivity), ["pid"] = c.Pid, ["sessionId"] = c.SessionId,
        ["teammates"] = MacMirror.Encode(c.Teammates), ["messages"] = new JsonArray(c.Messages.Select(Message).ToArray<JsonNode?>()),
        ["cwd"] = c.Cwd, ["kind"] = c.Kind, ["report"] = Report(c.Report), ["review"] = MacMirror.Encode(c.Review), ["ctx"] = MacMirror.Encode(c.Ctx),
        ["name"] = c.Name, ["captain"] = c.Captain, ["sameProject"] = MacMirror.Encode(c.SameProject), ["tasks"] = MacMirror.Encode(c.Tasks),
        ["visiting"] = c.Visiting, ["unused"] = c.Unused, ["activity"] = MacMirror.Encode(c.Activity), ["blockedReason"] = MacMirror.Encode(c.BlockedReason),
        ["subagents"] = MacMirror.Encode(c.Subagents), ["tokens"] = MacMirror.Encode(c.Tokens), ["permit"] = MacMirror.Encode(c.Permit), ["handover"] = c.Handover,
    };

    static JsonNode Message(TeamMessage m) => new JsonObject
    {
        ["from"] = m.From, ["text"] = m.Text, ["summary"] = m.Summary, ["timestamp"] = m.Timestamp, ["msg_id"] = m.MsgId, ["to"] = m.To,
    };

    /// Mac SelfReport 的 15 個欄位（11-02 P8：Windows 的 SelfReport 也讀 showork card 寫的 doing／options／how／kind／handoff／touch／outward）
    static JsonNode? Report(SelfReport? r) => r == null ? null : new JsonObject
    {
        ["status"] = MacMirror.Camel(r.Status.ToString()), ["progress"] = r.Progress, ["confidence"] = r.Confidence, ["summary"] = r.Summary, ["ask"] = r.Ask,
        ["report"] = r.Report, ["task"] = r.Task, ["doing"] = r.Doing, ["options"] = MacMirror.Encode(r.Options), ["how"] = r.How, ["kind"] = r.Kind, ["handoff"] = r.Handoff,
        ["touch"] = r.Touch, ["outward"] = r.Outward, ["at"] = MacMirror.Encode(r.At),
    };
}

/// 樓層號名冊＋閒晃角色（Mac TowerSource.swift 的 TowerStore；讀檔存檔在 Board/Source/OfficeSource.cs）
public static partial class TowerStore
{
    /// 卡片 → 閒晃的角色（同層依卡片 id 排座位，跟規範 §2.0 一致；沒有樓層的人不算）
    public static List<WanderPerson> people(IEnumerable<BoardCard> cards, TowerPlan tower)
    {
        var byFloor = new Dictionary<string, List<BoardCard>>();
        foreach (var c in cards)
        {
            if (c.Id.Contains('#')) continue;
            var fid = TowerFloor.projectId(c.Project);
            if (!byFloor.TryGetValue(fid, out var l)) byFloor[fid] = l = new();
            l.Add(c);
        }
        var out_ = new List<WanderPerson>();
        foreach (var (fid, cs) in byFloor)
        {
            if (tower.floor(fid) == null) continue;
            var sorted = cs.OrderBy(c => c.Id, StringComparer.Ordinal).ToList();
            for (int i = 0; i < sorted.Count; i++) out_.Add(new WanderPerson(sorted[i].Id, fid, Moods.Of(sorted[i]), i, sorted.Count));
        }
        return out_.OrderBy(p => p.Sid, StringComparer.Ordinal).ToList();
    }

    /// 測試用：SHOWORK_OFFICE_WANDER=off|instant（截圖要穩定）；不設＝animate
    public static WanderMode wanderMode => Environment.GetEnvironmentVariable("SHOWORK_OFFICE_WANDER") switch
    {
        "off" => WanderMode.off, "instant" => WanderMode.instant, _ => WanderMode.animate,
    };

    /// 測試用：SHOWORK_OFFICE_THEME=<專案>:<主題>[,<專案>:<主題>…] 強制主題（不寫檔）
    public static Dictionary<string, FloorDecor> themeOverrides(DateTime now)
    {
        var out_ = new Dictionary<string, FloorDecor>();
        if (Environment.GetEnvironmentVariable("SHOWORK_OFFICE_THEME") is not { } s) return out_;
        foreach (var pair in s.Split(','))
        {
            var kv = pair.Split(':', 2).Select(x => x.Trim()).ToArray();
            if (kv.Length != 2 || TowerThemes.from(kv[1]) is not { } t) continue;
            out_[kv[0].ToLowerInvariant()] = new FloorDecor(t, t.accent(), t.optionalProps().Take(2).ToList(), "測試強制", "test", now);
        }
        return out_;
    }
}

/// 推給網頁的一份資料
public static class Office2
{
    /// 天色：燈光設定＋主天氣（Mac OfficeView.body：lighting.look(at:site:).weathered(weather.look)）
    public static (SkyLook look, bool night) Sky(OfficeLighting lighting, DateTime now, WeatherSite site, WeatherNow? weather)
    {
        var look = lighting.look(now, site.coord).weathered(WeatherLook.of(weather));
        return (look, look.isNight);
    }

    public static JsonObject Payload(TowerPlan tower, IReadOnlyDictionary<string, FloorDecor> decor, WanderPlan wander, List<Island> islands,
                                     GuardStatus guardStatus, bool scanning, CityState? city, DateTime now,
                                     OfficeLighting lighting = OfficeLighting.auto, WeatherSite? site = null, WeatherNow? weather = null,
                                     NeuralGraph? graph = null, IReadOnlyDictionary<string, string>? colors = null, bool reduceMotion = false)
    {
        var s = site ?? WeatherSite.taipei;
        var (look, night) = Sky(lighting, now, s, weather);
        return new JsonObject
        {
            ["type"] = "office2",
            ["source"] = "win",
            ["now"] = MacMirror.Encode(now),
            ["tower"] = MacMirror.Encode(tower),
            ["decor"] = MacMirror.Encode(new SortedDictionary<string, FloorDecor>(decor.ToDictionary(kv => kv.Key, kv => kv.Value), StringComparer.Ordinal)),
            ["wander"] = MacMirror.Encode(wander),
            ["islands"] = MacMirror.Encode(islands),
            ["guardStatus"] = MacMirror.Encode(guardStatus),
            ["scanning"] = scanning,
            ["city"] = city == null ? null : MacMirror.Encode(city),        // null＝SHOWORK_CITY=off（Mac：CityMonitor.off 不畫城市）
            ["lighting"] = MacMirror.Camel(lighting.ToString()),
            ["look"] = MacMirror.Encode(look),
            ["night"] = night,
            ["site"] = MacMirror.Encode(s),
            ["weather"] = weather == null ? null : new JsonObject { ["now"] = MacMirror.Encode(weather), ["look"] = MacMirror.Encode(WeatherLook.of(weather)) },
            ["graph"] = MacMirror.Encode(graph ?? new NeuralGraph()),
            ["colors"] = MacMirror.Encode(colors?.ToDictionary(kv => kv.Key, kv => kv.Value) ?? new Dictionary<string, string>()),
            ["reduceMotion"] = reduceMotion,
        };
    }

    public static string Json(JsonObject o) => MacMirror.Json(o);
}

/// Mac OfficeView.swift 的 OfficeDemo：示範卡片（SHOWORK_OFFICE_DEMO=all|idle|floors）＋示範大樓（記憶體裡的名冊，不碰 board\tower.json）
public static class OfficeDemo
{
    public static string? mode => Environment.GetEnvironmentVariable("SHOWORK_OFFICE_DEMO");

    /// `base0`＝拿來當底的那張卡（Mac：第一張不是排隊的真卡片）；`now`＝示範的時間點
    public static List<BoardCard> apply(string? mode, List<BoardCard> cards, DateTime now, BoardCard? base0 = null)
    {
        var @base = base0 ?? cards.FirstOrDefault(c => !c.Id.Contains('#'));
        if (mode == null || @base == null) return cards;
        switch (mode)
        {
            case "idle":
                return cards.Select(c0 =>
                {
                    var c = Clone(c0);
                    if (c.Column is BoardColumn.Active or BoardColumn.Stuck) { c.Column = BoardColumn.Done; c.Reason = "閒置"; c.Activity = AIActivity.None; c.Subagents = new(); c.BlockedReason = null; }
                    return c;
                }).ToList();
            case "floors":
                {
                    // 10-25 夜景量測：N 個假專案各一層（SHOWORK_OFFICE_DEMO_FLOORS，預設 15），重現 Kang 十幾層的大樓
                    int n = int.TryParse(Environment.GetEnvironmentVariable("SHOWORK_OFFICE_DEMO_FLOORS"), out var x) ? x : 15;
                    return Enumerable.Range(0, n).Select(i =>
                    {
                        var c = Clone(@base);
                        c.Id = $"floor-{i}"; c.SessionId = c.Id; c.Project = $"Demo-F{i + 1:00}"; c.Title = $"F{i + 1}-工作";
                        c.Column = BoardColumn.Active; c.Reason = "工作中"; c.Activity = AIActivity.None; c.Report = null; c.Review = null; c.Captain = false;
                        c.Visiting = null; c.Unused = false; c.BlockedReason = null; c.Subagents = new(); c.Permit = null;
                        return c;
                    }).ToList();
                }
            case "all":
                {
                    var out_ = new List<BoardCard>();
                    void make(string project, string name, BoardColumn col, string reason, Action<BoardCard>? f = null)
                    {
                        var c = Clone(@base);
                        c.Id = $"demo-{out_.Count:00}"; c.SessionId = c.Id; c.Project = project; c.Title = name; c.Column = col; c.Reason = reason;
                        c.Report = null; c.Review = null; c.Captain = false; c.Visiting = null; c.Unused = false;
                        c.Activity = AIActivity.None; c.BlockedReason = null; c.Subagents = new();
                        c.Tokens = new TokenUsage(input: 1200 * (out_.Count + 1), output: 48_000 * (out_.Count + 1), cacheCreation: 310_000, cacheRead: 1_150_000 * (out_.Count + 1));
                        c.Detail = $"示範：{name}";
                        f?.Invoke(c); out_.Add(c);
                    }
                    foreach (var (n, a) in new[] { ("Reader-讀檔", AIActivity.Reading), ("Editor-改檔", AIActivity.Editing), ("Runner-跑指令", AIActivity.Running),
                                                   ("Seeker-搜尋", AIActivity.Searching), ("Thinker-思考", AIActivity.Thinking) })
                        make("Demo-動作", n, BoardColumn.Active, "工作中", c =>
                        {
                            c.Activity = a;
                            c.Report = new SelfReport { Status = ReportStatus.Working, Progress = 40 + out_.Count * 7, Confidence = 80, Summary = $"示範：{n}", At = now };
                        });
                    make("Demo-動作", "Boss-交辦", BoardColumn.Active, "工作中", c =>
                    {
                        c.Activity = AIActivity.Delegating;
                        c.Subagents = new() { new SubagentInfo("office3d-upgrade", "general-purpose"), new SubagentInfo("查 SceneKit 渲染", "Explore"),
                                              new SubagentInfo("local_workflow", "local_workflow", background: true), new SubagentInfo("寫測試", "general-purpose") };
                    });
                    foreach (var r in BlockedReasons.allCases.Where(r => r != BlockedReason.Unknown))
                        make("Demo-卡住", $"{r.rawValue()}-卡住", BoardColumn.Stuck, "超過 10 分鐘沒動靜", c => c.BlockedReason = r);
                    make("Demo-卡住", "Mystery-卡住", BoardColumn.Stuck, "超過 10 分鐘沒動靜");
                    make("Demo-等你", "Asker-權限", BoardColumn.Review, "等你回答", c =>
                    {
                        c.BlockedReason = BlockedReason.Permission; c.Detail = "要跑 rm -rf build/，等你按允許";
                        c.Permit = new PermitRequest { Id = "demo-permit", SessionId = c.SessionId, Tool = "Bash", Summary = "rm -rf build/ && swift build -c release",
                                                       Detail = "清掉舊的建置重新編譯",
                                                       AlwaysRules = """[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"swift build:*"}],"behavior":"allow","destination":"localSettings"}]""",
                                                       At = now.AddSeconds(-40) };
                    });
                    make("Demo-等你", "Quiz-選擇題", BoardColumn.Review, "等你回答", c =>
                    {
                        c.Permit = new PermitRequest { Id = "demo-ask", SessionId = c.SessionId, Tool = "AskUserQuestion", Summary = "午餐吃什麼？／要加什麼配料？", At = now.AddSeconds(-25),
                            Questions = new()
                            {
                                new AskQuestion { Question = "午餐吃什麼？", Header = "午餐", Options = new() { new("拉麵", "日式拉麵"), new("咖哩", "咖哩飯") } },
                                new AskQuestion { Question = "要加什麼配料？", Header = "配料", MultiSelect = true, Options = new() { new("蛋"), new("海苔"), new("叉燒") } },
                            } };
                    });
                    make("Demo-等你", "Planner-計畫", BoardColumn.Review, "等你回答", c =>
                    {
                        c.Permit = new PermitRequest { Id = "demo-plan", SessionId = c.SessionId, Tool = "ExitPlanMode", Summary = "計畫寫好了，要照這個做嗎？", At = now.AddSeconds(-10),
                            Input = """{"plan":"# 計畫：建立 hello.txt\n\n1. 在專案A 資料夾建立 **hello.txt**\n2. 內容寫一行 `hi`\n3. 跑 `cat hello.txt` 確認"}""" };
                    });
                    make("Demo-等你", "Chooser-決定", BoardColumn.Review, "要你決定：A 還是 B？", c =>
                        c.Report = new SelfReport { Status = ReportStatus.Review, Ask = "要用 A 方案（快）還是 B 方案（穩）？A 半天做完但只有單元測試；B 要一天但會加真機驗收。", At = now });
                    make("Demo-等你", "Done-做完", BoardColumn.Review, "做完了，你還沒看");
                    foreach (var n in new[] { "Coffee-休息", "Latte-休息", "Mocha-休息" }) make("Demo-休息", n, BoardColumn.Done, "閒置");
                    make("Demo-休息", "Sleepy-沒交代", BoardColumn.Done, "閒置", c => c.Unused = true);
                    make("Demo-隊長", "Captain-派工", BoardColumn.Active, "工作中", c => { c.Captain = true; c.Activity = AIActivity.Thinking; });
                    // 影分身：人住 Demo-休息、cd 去 Demo-動作逛（那層前帶畫半透明分身，驗證站位不穿家具）
                    foreach (var n in new[] { "Visitor-逛", "Guest-逛" }) make("Demo-休息", n, BoardColumn.Active, "工作中", c => c.Visiting = "Demo-動作");
                    return out_;
                }
            default:
                return cards;
        }
    }

    /// BoardCard 是 class（record）：示範卡片要各自一份
    static BoardCard Clone(BoardCard c) => c with
    {
        Teammates = c.Teammates.ToList(), Messages = c.Messages.ToList(), SameProject = c.SameProject.ToList(), Tasks = c.Tasks.ToList(), Subagents = c.Subagents.ToList(),
    };

    public static readonly Dictionary<string, TowerTheme> themes = new()
    {
        ["demo-動作"] = TowerTheme.app_studio, ["demo-卡住"] = TowerTheme.print_shop, ["demo-等你"] = TowerTheme.call_room,
        ["demo-休息"] = TowerTheme.library, ["demo-隊長"] = TowerTheme.monitor,
    };

    /// 示範資料的大樓（Mac TowerCache）：用一份記憶體裡的名冊（不碰你的 board\tower.json），示範專案依序配不同主題；閒晃延續上一次
    public sealed class TowerCache
    {
        readonly TowerRegistry reg = new();
        Dictionary<string, WanderState> prev = new();
        List<WanderCar> prevCars = new();        // 兩部電梯停哪、何時有空（10-22）
        string sig = "";
        (TowerPlan, Dictionary<string, FloorDecor>, WanderPlan) out_ = (new TowerPlan(), new(), new WanderPlan());

        public (TowerPlan plan, Dictionary<string, FloorDecor> decor, WanderPlan wander) make(List<OfficeDepartment> deps, List<BoardCard> cards,
                                                                                             IReadOnlyDictionary<string, FloorDecor> real, DateTime now, bool rain = false)
        {
            var s = string.Join(",", deps.Select(d => $"{d.Name}{d.IsActive}")) + "|" + string.Join(",", cards.Select(c => c.Id + MacMirror.Camel(Moods.Of(c).ToString())))
                    + $"|{(long)(MacMirror.Seconds(now) / WanderPlanner.bucket)}";
            if (s == sig) return out_;
            sig = s;
            var (plan, _) = TowerPlan.build(deps, cards, reg, () => new(), null, now);
            var d = real.ToDictionary(kv => kv.Key, kv => kv.Value);
            foreach (var f in plan.projectFloors)
            {
                if (f.Project is not { } name) continue;
                if (themes.TryGetValue(name.ToLowerInvariant(), out var t))
                    d[name.ToLowerInvariant()] = new FloorDecor(t, t.accent(), t.optionalProps().Take(3).ToList(), "示範", "test", now);
                else if (!d.ContainsKey(name.ToLowerInvariant()))
                    d[name.ToLowerInvariant()] = FloorDecor.local(WorkSignature.make(new DecorInput(name)), now);
            }
            foreach (var (k, v) in TowerStore.themeOverrides(now)) d[k] = v;
            var w = WanderPlanner.plan(TowerStore.people(cards, plan), plan, prev, now, visible: true, mode: TowerStore.wanderMode, rain: rain, cars0: prevCars);
            prev = w.States; prevCars = w.Cars;
            out_ = (plan, d, w);
            return out_;
        }
    }

    /// 示範資料的部門：常駐名冊照真的，示範專案當臨時部門接在後面
    public static List<OfficeDepartment> departments(List<OfficeDepartment> real, List<BoardCard> cards, string? mode) =>
        mode == null ? real : OfficeDepartments.build(real.Where(d => d.IsResident).Select(d => d.Name), cards);
}
