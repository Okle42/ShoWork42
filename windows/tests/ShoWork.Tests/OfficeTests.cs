using System.Text.Json;
using ShoWork;
using Xunit;

namespace ShoWork.Tests;

/// W6 3D 辦公大樓：BoardModel 卡片 → 推給 WebView2 頁面的 JSON（Office.cs）
public class OfficeTests
{
    static readonly DateTime T0 = new(2026, 11, 1, 9, 0, 0, DateTimeKind.Utc);

    static BoardCard Card(string id, string project, BoardColumn col, string reason = "", string title = "t", string? name = null, bool captain = false) =>
        new() { Id = id, Column = col, Reason = reason, Project = project, Title = title, Pid = 1, SessionId = id, Name = name, Captain = captain };

    static List<BoardCard> Demo() => new()
    {
        Card("a1", "ProjectA", BoardColumn.Active, "工作中", "Alice-整理名冊", captain: true),
        Card("a2", "ProjectA", BoardColumn.Review, "等你回答", "要不要上線", name: "Bob"),
        Card("b1", "ProjectB", BoardColumn.Review, "做完了，你還沒看", "報表"),
        Card("b1#q0", "ProjectB", BoardColumn.Todo, "排隊中，等這個 AI 有空", "下一件事"),
        Card("c1", "ProjectC", BoardColumn.Stuck, "41 分鐘沒有新動靜", "安裝包簽章"),
    };

    [Fact] // 樓層順序：大廳 → 專案（照樓層號）→ 頂樓；桌子＝實際 AI 數（排隊卡不算）
    public void FloorsAndSeats()
    {
        var reg = new TowerRegistry();
        var (s, dirty) = OfficeScene.Build(Demo(), reg, T0);
        Assert.True(dirty);
        Assert.Equal(new[] { "lobby", "project", "project", "project", "roof" }, s.Floors.Select(f => f.Kind));
        Assert.Equal(new[] { "01", "02", "03", "04", "RF" }, s.Floors.Select(f => f.FloorNo));
        var b = s.Floors.Single(f => f.Project == "ProjectB");
        Assert.Equal(1, b.Seats);
        Assert.Equal(1, b.Queued);
        Assert.Equal(2, s.Floors.Single(f => f.Project == "ProjectA").Seats);
        Assert.All(s.Floors.Where(f => f.Kind == "project"), f => Assert.True(f.Active));
        Assert.Equal(new OfficeCounts(1, 1, 1, 1), s.Counts);
    }

    [Fact] // 角色：狀態、配件、英文名＋任務（名字-任務的標題拆開；session 名是英文名就用；都沒有就從名字池挑、不重複）
    public void People()
    {
        var (s, _) = OfficeScene.Build(Demo(), new TowerRegistry(), T0);
        var a = s.Floors.Single(f => f.Project == "ProjectA").People;
        var alice = a.Single(p => p.Id == "a1");
        Assert.Equal(("Alice", "整理名冊", "working", "crown", true), (alice.Name, alice.Task, alice.Mood, alice.Accessory, alice.Captain));
        var bob = a.Single(p => p.Id == "a2");
        Assert.Equal(("Bob", "要不要上線", "waiting"), (bob.Name, bob.Task, bob.Mood));
        Assert.Equal("finished", s.Floors.Single(f => f.Project == "ProjectB").People.Single().Mood);
        Assert.Equal("stuck", s.Floors.Single(f => f.Project == "ProjectC").People.Single().Mood);
        var names = s.Floors.SelectMany(f => f.People).Select(p => p.Name).ToList();
        Assert.Equal(names.Count, names.Distinct().Count());
        Assert.All(names, n => Assert.Matches("^[A-Z][A-Za-z0-9]*$", n));
        // 同一個 session 每次挑到同一個名字
        var (s2, _) = OfficeScene.Build(Demo(), new TowerRegistry(), T0);
        Assert.Equal(names, s2.Floors.SelectMany(f => f.People).Select(p => p.Name));
    }

    [Fact] // 名字解析：you-88 這種自動名、只有一個英文字的標題不算名字；任務太長截斷
    public void NameParsing()
    {
        Assert.Equal(("Chris", "修 bug"), OfficeNames.Parse("Chris-修 bug")!.Value);
        Assert.Null(OfficeNames.Parse("you-88"));
        Assert.Null(OfficeNames.Parse("戰情中心"));
        var m = OfficeNames.Assign(new[] { Card("x", "P", BoardColumn.Active, title: "README") });
        Assert.NotEqual("README", m["x"].Name);
        Assert.Equal("README", m["x"].Task);
        Assert.EndsWith("⋯", OfficeNames.Clean(new string('字', 30)));
    }

    [Fact] // 固定樓層號：專案離開再回來號碼不變；新專案接在最後；全部 AI 走了 2 小時內樓層留著（燈暗），之後降到閒置薄層
    public void FixedNumbersAndDemotion()
    {
        var reg = new TowerRegistry();
        OfficeScene.Build(Demo(), reg, T0);
        Assert.Equal(3, reg.Number("projectb"));
        // ProjectB 的人走了、來了新專案 ProjectD
        var later = Demo().Where(c => c.Project != "ProjectB").Append(Card("d1", "ProjectD", BoardColumn.Active, "工作中")).ToList();
        var (s1, _) = OfficeScene.Build(later, reg, T0.AddMinutes(30));
        var b = s1.Floors.Single(f => f.Project == "ProjectB");
        Assert.False(b.Active);
        Assert.Equal(0, b.Seats);
        Assert.Equal("05", s1.Floors.Single(f => f.Project == "ProjectD").FloorNo);
        // 2 小時後：ProjectB 降到閒置薄層（只剩門牌，號碼還記著）
        var (s2, _) = OfficeScene.Build(later, reg, T0.AddHours(3));
        Assert.DoesNotContain(s2.Floors, f => f.Project == "ProjectB");
        var idle = s2.Floors.Single(f => f.Kind == "idle");
        Assert.Equal(new OfficePlate("ProjectB", "03"), idle.Plates.Single());
        Assert.Equal("idle", s2.Floors[1].Kind);                     // 薄層在大廳正上方
        // 回來：還是 03
        var (s3, _) = OfficeScene.Build(Demo(), reg, T0.AddHours(4));
        Assert.Equal("03", s3.Floors.Single(f => f.Project == "ProjectB").FloorNo);
    }

    [Fact] // 名冊存檔讀回一樣；壞掉的檔案當空的
    public void RegistryRoundTrip()
    {
        var reg = new TowerRegistry();
        OfficeScene.Build(Demo(), reg, T0);
        var back = TowerRegistry.Decode(reg.Encode());
        Assert.Equal(reg.Numbers, back.Numbers);
        Assert.Equal(reg.Active, back.Active);
        Assert.Equal(reg.LastSeen.Keys.Order(), back.LastSeen.Keys.Order());
        Assert.Empty(TowerRegistry.Decode("{壞掉").Numbers);
        Assert.Empty(TowerRegistry.Decode(null).Numbers);
    }

    [Fact] // 主題：專案名關鍵字命中就用；沒命中照名字雜湊穩定挑（不是通用辦公）；快取的 theme id 優先
    public void Themes()
    {
        Assert.True(OfficeThemes.All.Length >= 6);
        Assert.Equal("game_lab", OfficeThemes.Pick("PokerGame").Id);
        Assert.Equal("dispatch_room", OfficeThemes.Pick("RideShare2").Id);
        Assert.Equal("Demo Line 42", OfficeThemes.SplitName("DemoLine42"));
        var p = OfficeThemes.Pick("ProjectA");
        Assert.Equal(p, OfficeThemes.Pick("ProjectA"));
        Assert.Equal(p, OfficeThemes.Pick("projecta"));
        Assert.NotEqual("general", p.Id);
        Assert.Equal("legal_room", OfficeThemes.Pick("ProjectA", decor: "legal_room").Id);
        Assert.Equal(p, OfficeThemes.Pick("ProjectA", decor: "不認得"));
        Assert.All(OfficeThemes.All, t => Assert.Matches("^#[0-9A-F]{6}$", t.Accent));
    }

    [Fact] // JSON：camelCase、沒有值的不印、中文不跳脫；頁面要的欄位都在
    public void JsonShape()
    {
        var colors = new Dictionary<string, string> { ["working"] = "#9E66FF" };
        var (s, _) = OfficeScene.Build(Demo(), new TowerRegistry(), T0, colors: colors, reduceMotion: true);
        var json = OfficeScene.Json(s);
        Assert.Contains("\"type\":\"office\"", json);
        Assert.Contains("整理名冊", json);
        Assert.DoesNotContain("\\u", json);
        using var doc = JsonDocument.Parse(json);
        var r = doc.RootElement;
        Assert.True(r.GetProperty("reduceMotion").GetBoolean());
        Assert.Equal("#9E66FF", r.GetProperty("colors").GetProperty("working").GetString());
        Assert.Equal(1, r.GetProperty("counts").GetProperty("waiting").GetInt32());
        var floor = r.GetProperty("floors")[1];
        foreach (var k in new[] { "kind", "id", "floorNo", "project", "number", "active", "seats", "theme", "themeTitle", "accent", "people", "plates" })
            Assert.True(floor.TryGetProperty(k, out _), k);
        var person = floor.GetProperty("people")[0];
        foreach (var k in new[] { "id", "name", "task", "mood", "captain", "reason", "title" })
            Assert.True(person.TryGetProperty(k, out _), k);
        Assert.False(r.GetProperty("floors")[0].TryGetProperty("project", out _));   // 大廳沒有專案：null 不印
        // 沒變就一樣（BoardForm 拿 JSON 字串比對決定要不要推）
        Assert.Equal(json, OfficeScene.Json(OfficeScene.Build(Demo(), new TowerRegistry(), T0, colors: colors, reduceMotion: true).Snapshot));
    }

    [Fact] // 沒有任何 session：只有大廳和頂樓
    public void Empty()
    {
        var (s, _) = OfficeScene.Build(Array.Empty<BoardCard>(), new TowerRegistry(), T0);
        Assert.Equal(new[] { "lobby", "roof" }, s.Floors.Select(f => f.Kind));
    }
}
