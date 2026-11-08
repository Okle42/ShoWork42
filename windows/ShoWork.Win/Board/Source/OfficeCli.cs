using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ShoWork;

/// 唯讀的檢查入口（11-02 P8，比照 --board-dump）：
///   --city-dump      跑一輪城市資料來源（磁碟、雲端、ssh 主機、防火牆＋城門、港口、額度、天氣、圖譜），印出真實的 CityState（Mac Mirror 格式）
///   --office-dump    看板目前的卡片 → office2 JSON（推給網頁的那一份）；--board-demo 用示範卡片
///   --out <檔案>     寫到檔案（UTF-8），不印到 stdout
/// 都不寫名冊、不寫主題快取、不呼叫 claude（OfficeSource official=false）
public static class OfficeCli
{
    [DllImport("kernel32.dll")] static extern bool AttachConsole(uint pid);

    public static int Run(string[] args)
    {
        if (OperatingSystem.IsWindows()) AttachConsole(unchecked((uint)-1));
        try
        {
            CityMonitor.testWindow = true;          // 不寫回 city.json
            var now = DateTime.UtcNow;
            JsonNode? outp;
            if (args[0] == "--city-dump")
            {
                var city = CityMonitor.shared.runOnce();
                var w = new OfficeWeather(testMode: false);
                var wn = w.fetchNow();
                outp = new JsonObject
                {
                    ["city"] = MacMirror.Encode(city),
                    ["alerts"] = MacMirror.Encode(city.alerts),
                    ["labels"] = new JsonArray(city.Disks.Select(d => (JsonNode?)CityText.disk(d))
                                                .Concat(city.Clouds.Select(c => (JsonNode?)CityText.cloud(c)))
                                                .Concat(city.Servers.Select(s => (JsonNode?)CityText.server(s)))
                                                .Append(CityText.wall(city.Firewall)).Append(city.Firewall.summary)
                                                .Append(CityText.grid(city.Grid, now)).Append(CityText.fuel(city.Grid)).Append(CityText.power(city.Power)).ToArray()),
                    ["repoRoots"] = MacMirror.Encode(CityPaths.repoRoots()),
                    ["repos"] = MacMirror.Encode(CityPaths.repos().Keys.OrderBy(x => x).ToList()),
                    ["sshConfig"] = CityPaths.sshConfig,
                    ["weatherSite"] = MacMirror.Encode(w.main),
                    ["weather"] = MacMirror.Encode(wn),
                    ["weatherKind"] = wn == null ? null : MacMirror.Camel(wn.kind.ToString()),
                    ["sky"] = OfficeLighting.auto.label(now, w.main.coord),
                    ["graphify"] = GraphSource.graphify(),
                    ["claude"] = DecorRunner.claude() is { } c ? string.Join(" ", c.pre.Prepend(c.exe)) : null,
                };
            }
            else
            {
                var demo = args.Contains("--board-demo");
                var reader = BoardReader.Default();
                var cards = demo ? BoardDemo.Cards(now) : reader.Cards(reader.Read(), now);
                var src = new OfficeSource(demo, official: false);
                var city = CityMonitor.off ? null : CityMonitor.shared.runOnce();
                var w = new OfficeWeather(testMode: true);
                outp = JsonNode.Parse(src.Build(cards, now, city, w.main, w.current, new GraphSource().consider(src.Tower, now)));
            }
            var json = outp!.ToJsonString(new JsonSerializerOptions { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }) + "\n";
            // --out 檔案：直接寫檔（WinExe 的 stdout 經 PowerShell／cmd 轉向會被改字碼或不等它結束）
            var outFile = args.SkipWhile(a => a != "--out").Skip(1).FirstOrDefault();
            if (outFile != null) { File.WriteAllText(outFile, json, new System.Text.UTF8Encoding(false)); return 0; }
            try { Console.OutputEncoding = new System.Text.UTF8Encoding(false); } catch { }
            using var o = Console.OpenStandardOutput();
            var b = new System.Text.UTF8Encoding(false).GetBytes(json);
            o.Write(b, 0, b.Length);
            return 0;
        }
        catch (Exception e) { Console.Error.WriteLine($"error: {e}"); return 1; }
    }
}
