using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;
using ShoWork;

// W2 checks without any window: settings.json robustness and round trip, the reduce-motion fallback,
// and the frame cost of every glow style for an 882×471 px window at 150 % (what w2_glow.ps1 uses).
int fails = 0;
void Check(string name, bool ok, string detail = "") { Console.WriteLine($"  {(ok ? "PASS" : "FAIL")} {name} {detail}"); if (!ok) fails++; }

// settings.json: one broken entry falls back to its default, out-of-range values are clamped, the rest kept
var home = Path.Combine(Path.GetTempPath(), "sw42-w2-check-" + Environment.ProcessId);
Directory.CreateDirectory(home);
Environment.SetEnvironmentVariable("SHOWORK_HOME", home);
File.WriteAllText(Path.Combine(home, "settings.json"), """
    {"v":1,"looks":{"working":{"enabled":false,"hex":"#123456","style":"aurora","speed":9,"brightness":0.1,"width":1.2},
                    "done":{"hex":5},"input":{"enabled":true,"hex":"nope","style":"ripple"}},
     "general":{"autoArrange":true}}
    """);
var gs = GlowSettings.Shared;
var w = gs.Look(WorkState.Working);
Check("working kept and clamped", !w.Enabled && w.Hex == "#123456" && w.Style == GlowStyle.Aurora && w.Speed == 2.5 && w.Brightness == 0.3 && w.Width == 1.2, w.ToString());
Check("broken done entry -> default", gs.Look(WorkState.Done) == GlowSettings.Defaults[WorkState.Done], gs.Look(WorkState.Done).ToString());
Check("bad colour -> white, style kept", gs.Look(WorkState.Input) is { Hex: "#FFFFFF", Style: GlowStyle.Ripple }, gs.Look(WorkState.Input).ToString());
Check("general read", gs.General.AutoArrange);
Check("no direction in an old file -> inward", gs.General.Direction == GlowDirection.Inward && gs.Inward, gs.General.ToString());
Check("idle lights nothing", !gs.Look(WorkState.Idle).Enabled);
int changed = 0;
gs.Changed += () => changed++;
gs.Set(WorkState.Done, gs.Look(WorkState.Done) with { Style = GlowStyle.Sparkle, Speed = 0.1 });
gs.Set(WorkState.Done, gs.Look(WorkState.Done));                         // no change: no event
gs.Flush();
var saved = JsonNode.Parse(File.ReadAllText(GlowSettings.PathOnDisk))!;
Check("Changed fires once per real change", changed == 1, $"{changed}");
Check("saved: done sparkle, speed clamped to 0.4", (string?)saved["looks"]!["done"]!["style"] == "sparkle" && (double)saved["looks"]!["done"]!["speed"]! == 0.4, saved["looks"]!["done"]!.ToJsonString());
Check("saved: no temp file left", !File.Exists(GlowSettings.PathOnDisk + ".tmp"));
Check("saved: direction inward", (string?)saved["general"]!["direction"] == "inward", saved["general"]!.ToJsonString());
GlowSettings Fresh(string general)
{
    File.WriteAllText(GlowSettings.PathOnDisk, "{\"v\":1,\"general\":" + general + "}");
    return (GlowSettings)Activator.CreateInstance(typeof(GlowSettings), nonPublic: true)!;
}
Check("direction outward read, autoArrange kept", Fresh("{\"autoArrange\":true,\"direction\":\"outward\"}").General is { Direction: GlowDirection.Outward, AutoArrange: true });
Check("direction garbage -> inward, autoArrange kept", Fresh("{\"autoArrange\":true,\"direction\":\"sideways\"}").General is { Direction: GlowDirection.Inward, AutoArrange: true });
Check("direction number -> inward", Fresh("{\"direction\":7}").General.Direction == GlowDirection.Inward);
Directory.Delete(home, true);

// animation effects off: every style is a still glow drawn once, in one window
foreach (var st in Enum.GetValues<GlowStyle>())
{
    using var a = new GlowArt(new StateLook(true, "#9E66FF", st), new Size(882, 471), 1.5f, still: true, inward: false);
    if (a.Style != GlowStyle.Breathe || a.Fps != 0 || a.Breathes || a.Parts.Length != 1) Check($"still {st}", false, $"{a.Style} fps={a.Fps} parts={a.Parts.Length}");
    using var b = new GlowArt(new StateLook(true, "#9E66FF", st), new Size(882, 471), 1.5f, still: true, inward: true);
    if (b.Style != GlowStyle.Breathe || b.Fps != 0 || b.Parts.Length != 1 || b.Pad != 0 || b.Parts[0].Size != new Size(882, 471)) Check($"still inward {st}", false, $"{b.Style} fps={b.Fps} parts={b.Parts.Length}");
}
Check("reduce motion: all six styles fall back to a still glow", true);

// inward: the strips tile exactly the band inside the edge; the middle and everything outside stay transparent;
// the edge line is the brightest part and the soft light inside stays faint (terminal text under it)
unsafe
{
    foreach (var style in Enum.GetValues<GlowStyle>())
    {
        var sz = new Size(882, 471);
        using var art = new GlowArt(new StateLook(true, "#9E66FF", style), sz, 1.5f, pad => new[] { new Rectangle(-20, -20, sz.Width + 40, sz.Height + 40) }, still: false, inward: true);
        var buf = (uint*)NativeMemory.AllocZeroed((nuint)((sz.Width + 40) * (sz.Height + 40) * 4));
        art.Draw(5, new[] { buf });
        int W = sz.Width + 40;
        byte Al(int x, int y) => (byte)(buf[(y + 20) * W + x + 20] >> 24);
        int outsideMax = 0, middleMax = 0;
        for (int y = -20; y < sz.Height + 20; y++)
            for (int x = -20; x < sz.Width + 20; x++)
            {
                bool inside = x >= 0 && y >= 0 && x < sz.Width && y < sz.Height;
                if (!inside) outsideMax = Math.Max(outsideMax, Al(x, y));
                else if (x > art.Depth + 1 && y > art.Depth + 1 && x < sz.Width - art.Depth - 1 && y < sz.Height - art.Depth - 1) middleMax = Math.Max(middleMax, Al(x, y));
            }
        int edge = Al(1, sz.Height / 2), deep = Al(8, sz.Height / 2), deeper = Al(16, sz.Height / 2);
        var strips = GlowArt.InnerStrips(sz, art.Depth, 12);
        long area = strips.Sum(r => (long)r.Width * r.Height), band = (long)sz.Width * sz.Height - (long)(sz.Width - 2 * (art.Depth + 1)) * (sz.Height - 2 * (art.Depth + 1));
        bool disjoint = strips.All(a => strips.All(b => a == b || !a.IntersectsWith(b)));
        Check($"inward {style}: outside 0, middle 0, strips tile the band", outsideMax == 0 && middleMax == 0 && disjoint && area == band,
              $"depth={art.Depth} outside={outsideMax} middle={middleMax} strips={area}/{band} alpha edge={edge} 8px={deep} 16px={deeper}");
        NativeMemory.Free(buf);
    }
}

unsafe
{
    foreach (var (style, inward) in Enum.GetValues<GlowStyle>().SelectMany(st => new[] { (st, false), (st, true) }))
    {
        using var art = new GlowArt(new StateLook(true, "#9E66FF", style), new Size(882, 471), 1.5f, still: false, inward: inward);
        var bits = new uint*[art.Parts.Length];
        for (int i = 0; i < bits.Length; i++) bits[i] = (uint*)NativeMemory.AllocZeroed((nuint)(art.Parts[i].Width * art.Parts[i].Height * 4));
        for (int i = 0; i < 200; i++) art.Draw(i / 30.0, bits);                     // warm up (tiered JIT)
        var sw = Stopwatch.StartNew();
        int n = 300;
        for (int i = 0; i < n; i++) art.Draw(10 + i / 30.0, bits);
        long px = art.Parts.Sum(p => (long)p.Width * p.Height);
        Console.WriteLine($"  {style,-8} {(inward ? "in " : "out")} pad {art.Pad,3} depth {art.Depth,3}  {art.Parts.Length} part(s) {px,7} px  fps {art.Fps,2}  {sw.Elapsed.TotalMilliseconds / n:0.000} ms/frame");
        foreach (var b in bits) NativeMemory.Free(b);
    }
}
Console.WriteLine(fails == 0 ? "ALL PASS" : $"{fails} FAILED");
return fails;
