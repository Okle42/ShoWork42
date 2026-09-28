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
Directory.Delete(home, true);

// animation effects off: every style is a still glow drawn once, in one window
foreach (var st in Enum.GetValues<GlowStyle>())
{
    using var a = new GlowArt(new StateLook(true, "#9E66FF", st), new Size(882, 471), 1.5f, still: true);
    if (a.Style != GlowStyle.Breathe || a.Fps != 0 || a.Breathes || a.Parts.Length != 1) Check($"still {st}", false, $"{a.Style} fps={a.Fps} parts={a.Parts.Length}");
}
Check("reduce motion: all six styles fall back to a still glow", true);

unsafe
{
    foreach (var style in Enum.GetValues<GlowStyle>())
    {
        using var art = new GlowArt(new StateLook(true, "#9E66FF", style), new Size(882, 471), 1.5f, still: false);
        var bits = new uint*[art.Parts.Length];
        for (int i = 0; i < bits.Length; i++) bits[i] = (uint*)NativeMemory.AllocZeroed((nuint)(art.Parts[i].Width * art.Parts[i].Height * 4));
        for (int i = 0; i < 200; i++) art.Draw(i / 30.0, bits);                     // warm up (tiered JIT)
        var sw = Stopwatch.StartNew();
        int n = 300;
        for (int i = 0; i < n; i++) art.Draw(10 + i / 30.0, bits);
        long px = art.Parts.Sum(p => (long)p.Width * p.Height);
        Console.WriteLine($"  {style,-8} pad {art.Pad,3}  {art.Parts.Length} part(s) {px,7} px  fps {art.Fps,2}  {sw.Elapsed.TotalMilliseconds / n:0.000} ms/frame");
        foreach (var b in bits) NativeMemory.Free(b);
    }
}
Console.WriteLine(fails == 0 ? "ALL PASS" : $"{fails} FAILED");
return fails;
