using System.Drawing;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace ShoWork;

/// Outer-glow styles from the 09-26 decision board (docs/decisions/glow_style_board.html), same as the Mac GlowStyle.
public enum GlowStyle { Breathe, Orbit, Ripple, Drift, Sparkle, Aurora }

/// How one state (working / done / input) looks. Kang 09-26: every state is tuned on its own — on/off,
/// colour, style, speed, brightness, width. Same fields and ranges as the Mac StateLook.
public sealed record StateLook(bool Enabled, string Hex, GlowStyle Style, double Speed = 1, double Brightness = 1, double Width = 1)
{
    /// animation durations are multiplied by this (speed 0.4…2.5, higher = faster)
    [JsonIgnore] public double Period => 1 / Math.Clamp(Speed, 0.4, 2.5);
    /// 0.3…1.6: how strong the light is
    [JsonIgnore] public float B => (float)Math.Clamp(Brightness, 0.3, 1.6);
    /// 0.5…2: how far the outer glow spreads
    [JsonIgnore] public float W => (float)Math.Clamp(Width, 0.5, 2);
    [JsonIgnore] public Color Color => ParseHex(Hex) ?? Color.White;

    public static Color? ParseHex(string? s) =>
        s is { Length: 7 } && s[0] == '#' && int.TryParse(s.AsSpan(1), System.Globalization.NumberStyles.HexNumber, null, out var v)
            ? Color.FromArgb((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF) : null;
    public static string ToHex(Color c) => $"#{c.R:X2}{c.G:X2}{c.B:X2}";

    /// Values from disk are the user's (or a hand edit): keep them inside the ranges the UI offers.
    public StateLook Clamped() => this with
    {
        Hex = ParseHex(Hex) is { } c ? ToHex(c) : "#FFFFFF",
        Style = Enum.IsDefined(Style) ? Style : GlowStyle.Breathe,
        Speed = Math.Clamp(Speed, 0.4, 2.5), Brightness = Math.Clamp(Brightness, 0.3, 1.6), Width = Math.Clamp(Width, 0.5, 2),
    };
}

/// Settings that are not about the glow. AutoArrange is off by default on Windows (the arranger reads it).
public sealed record GeneralSettings(bool AutoArrange = false, bool Autostart = false);

/// Glow looks and general settings, persisted as %LOCALAPPDATA%\ShoWork42\settings.json. Changes apply at once
/// (Changed fires on the UI thread) and reach the disk shortly after, so dragging a slider is not a write per pixel.
sealed class GlowSettings
{
    static GlowSettings? shared;
    /// Loaded on first use (after the static defaults below exist).
    public static GlowSettings Shared => shared ??= new();

    public static readonly IReadOnlyDictionary<WorkState, StateLook> Defaults = new Dictionary<WorkState, StateLook>
    {
        [WorkState.Working] = new(true, "#9E66FF", GlowStyle.Breathe),
        [WorkState.Done] = new(true, "#30D158", GlowStyle.Breathe),     // Kang 09-26：完成由金改綠
        [WorkState.Input] = new(true, "#FF4040", GlowStyle.Breathe),
    };
    static readonly StateLook Off = new(false, "#000000", GlowStyle.Breathe);

    readonly Dictionary<WorkState, StateLook> looks = new(Defaults);
    System.Windows.Forms.Timer? saveSoon;

    /// Fired after any change, on the UI thread.
    public event Action? Changed;
    public GeneralSettings General { get; private set; } = new();

    public static string PathOnDisk => Path.Combine(Wire.SupportDir, "settings.json");

    static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };

    GlowSettings() => Load();

    public StateLook Look(WorkState s) => looks.GetValueOrDefault(s, Off);

    public void Set(WorkState s, StateLook look)
    {
        if (!looks.ContainsKey(s) || looks[s] == look) return;
        looks[s] = look.Clamped();
        Commit();
    }

    public void Reset(WorkState s) { if (Defaults.TryGetValue(s, out var d)) Set(s, d); }

    public void SetGeneral(GeneralSettings g)
    {
        if (g == General) return;
        General = g;
        Commit();
    }

    void Commit()
    {
        Changed?.Invoke();
        if (saveSoon == null)
        {
            saveSoon = new System.Windows.Forms.Timer { Interval = 400 };
            saveSoon.Tick += (_, _) => Flush();
        }
        saveSoon.Stop();
        saveSoon.Start();
    }

    /// Write now (the settings window calls this when it closes; the agent may quit right after).
    public void Flush()
    {
        saveSoon?.Stop();
        try
        {
            var o = new JsonObject
            {
                ["v"] = 1,
                ["looks"] = new JsonObject(looks.Select(kv => KeyValuePair.Create(Key(kv.Key), JsonSerializer.SerializeToNode(kv.Value, Json)))),
                ["general"] = JsonSerializer.SerializeToNode(General, Json),
            };
            Directory.CreateDirectory(Wire.SupportDir);
            var tmp = PathOnDisk + ".tmp";
            File.WriteAllText(tmp, o.ToJsonString(Json));
            File.Move(tmp, PathOnDisk, overwrite: true);           // never a half-written settings file
        }
        catch (Exception e) { Log.Note($"SETTINGS save {e.Message}"); }
    }

    static string Key(WorkState s) => s.ToString().ToLowerInvariant();

    /// Each state is read on its own: one broken entry falls back to its default, the others are kept.
    void Load()
    {
        try
        {
            if (!File.Exists(PathOnDisk)) return;
            var root = JsonNode.Parse(File.ReadAllText(PathOnDisk)) as JsonObject;
            if (root?["looks"] is JsonObject l)
                foreach (var s in Defaults.Keys)
                    try { if (l[Key(s)]?.Deserialize<StateLook>(Json) is { } v && v.Hex != null) looks[s] = v.Clamped(); }
                    catch (Exception e) { Log.Note($"SETTINGS {Key(s)}: {e.Message}"); }
            if (root?["general"] is JsonObject g)
                try { General = g.Deserialize<GeneralSettings>(Json) ?? General; } catch (Exception e) { Log.Note($"SETTINGS general: {e.Message}"); }
        }
        catch (Exception e) { Log.Note($"SETTINGS load {e.Message}"); }
    }

    /// Windows "Animation effects" off (Settings › Accessibility › Visual effects) = the Mac's Reduce Motion:
    /// every style falls back to a still glow.
    public static bool ReduceMotion => SystemParametersInfo(SPI_GETCLIENTAREAANIMATION, 0, out int on, 0) && on == 0;
    public const int SPI_GETCLIENTAREAANIMATION = 0x1042, SPI_SETCLIENTAREAANIMATION = 0x1043;
    [DllImport("user32.dll")] static extern bool SystemParametersInfo(int action, int param, out int value, int winIni);

    public static string Title(GlowStyle s) => s switch
    {
        GlowStyle.Breathe => "呼吸", GlowStyle.Orbit => "流光繞行", GlowStyle.Ripple => "漣漪外擴",
        GlowStyle.Drift => "光霧飄動", GlowStyle.Sparkle => "微光粒子", _ => "極光旋轉",
    };
}
