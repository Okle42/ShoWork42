using System.Globalization;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ShoWork.Hooks;

// showork.exe 的 hook 端（W5：卡片、閘門、放行）共用的小工具：路徑、JSON、字串。
// 這個資料夾（windows/showork/Core）不碰 WinForms、不呼叫 Win32，測試（windows/tests/ShoWork.Tests）在 macOS 上也能跑。
// 資料檔格式跟 Mac 版（Sources/ShoWorkCore）一模一樣：欄位名、時間格式（ISO 8601 帶毫秒、UTC）、資料夾結構都相同，
// 只是根目錄在 %LOCALAPPDATA%\ShoWork42（Wire.SupportDir，SHOWORK_HOME 可改）。
// showork.csproj 是 PublishAot：不用反射式 JsonSerializer，一律 JsonNode／Utf8JsonWriter。

/// 路徑（Mac：Paths.supportDir、Captain.dir、Peer.claudeDir）
static class HookPaths
{
    public static string Support => Wire.SupportDir;
    public static string Board => Path.Combine(Support, "board");
    public static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    /// SHOWORK_CLAUDE_DIR 給測試用（同 Mac 的 Peer.claudeDir）
    public static string ClaudeDir => Env("SHOWORK_CLAUDE_DIR") ?? Path.Combine(Home, ".claude");
    public static string? Env(string k) => Environment.GetEnvironmentVariable(k) is { Length: > 0 } v ? v : null;
}

static class HookJson
{
    static readonly JsonWriterOptions Relaxed = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    /// 同 Mac 的 BoardJSON：時間一律帶毫秒（2026-10-31T09:03:20.841Z）
    public static string Iso(DateTime d) => d.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);

    static readonly string[] IsoFormats = { "yyyy-MM-dd'T'HH:mm:ss.FFFFFFFK", "yyyy-MM-dd'T'HH:mm:ssK" };
    /// 帶不帶小數秒都吃（Mac 的 decoder 也是）；一定要有時區
    public static DateTime? ParseIso(string? s)
    {
        if (s == null || !(s.EndsWith('Z') || s.Length > 6 && (s[^6] == '+' || s[^6] == '-'))) return null;
        return DateTime.TryParseExact(s, IsoFormats, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal, out var d) ? d : null;
    }

    /// 緊湊的 JSON（中文不轉 \uXXXX，跟 Mac 寫出來的一樣好讀）
    public static string Text(JsonNode n)
    {
        using var ms = new MemoryStream();
        using (var w = new Utf8JsonWriter(ms, Relaxed)) n.WriteTo(w);
        return Encoding.UTF8.GetString(ms.ToArray());
    }

    public static string Write(Action<Utf8JsonWriter> f)
    {
        using var ms = new MemoryStream();
        using (var w = new Utf8JsonWriter(ms, Relaxed)) f(w);
        return Encoding.UTF8.GetString(ms.ToArray());
    }

    public static JsonNode? Parse(string? text)
    {
        if (string.IsNullOrEmpty(text)) return null;
        try { return JsonNode.Parse(text); } catch { return null; }
    }

    public static JsonObject? ReadObject(string path) => Parse(ReadText(path)) as JsonObject;

    public static string? ReadText(string path)
    {
        try
        {
            if (!File.Exists(path)) return null;
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var sr = new StreamReader(fs, Encoding.UTF8);
            return sr.ReadToEnd();
        }
        catch { return null; }
    }

    /// 先寫暫存檔再換名（同 Mac 的 .atomic）：看板讀到的永遠是完整的檔
    public static bool WriteAtomic(string path, string text)
    {
        try
        {
            var dir = Path.GetDirectoryName(path)!;
            Directory.CreateDirectory(dir);
            var tmp = Path.Combine(dir, $".{Path.GetFileName(path)}.{Environment.ProcessId}.tmp");
            File.WriteAllText(tmp, text, new UTF8Encoding(false));
            File.Move(tmp, path, overwrite: true);
            return true;
        }
        catch { return false; }
    }

    /// jsonl 加一行
    public static void AppendLine(string path, string line)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.AppendAllText(path, line.Replace("\n", "") + "\n", new UTF8Encoding(false));
        }
        catch { }
    }

    public static IEnumerable<string> Files(string dir, string pattern)
    {
        try { return Directory.Exists(dir) ? Directory.GetFiles(dir, pattern) : Array.Empty<string>(); }
        catch { return Array.Empty<string>(); }
    }

    // MARK: 讀欄位（型別不對就當沒有，同 Swift 的 try? decode 寬鬆的那一半）

    public static string? Str(this JsonNode? o, string k) =>
        o is JsonObject j && j[k] is JsonValue v && v.GetValueKind() == JsonValueKind.String ? v.GetValue<string>() : null;
    public static int? Int(this JsonNode? o, string k) =>
        o is JsonObject j && j[k] is JsonValue v && v.GetValueKind() == JsonValueKind.Number ? (int)v.GetValue<double>() : null;
    public static bool Bool(this JsonNode? o, string k) =>
        o is JsonObject j && j[k] is JsonValue v && v.GetValueKind() == JsonValueKind.True;
    public static DateTime? Date(this JsonNode? o, string k) => ParseIso(o.Str(k));
    public static List<string> Strs(this JsonNode? o, string k) =>
        o is JsonObject j && j[k] is JsonArray a
            ? a.Where(x => x is JsonValue v && v.GetValueKind() == JsonValueKind.String).Select(x => x!.GetValue<string>()).ToList()
            : new List<string>();

    public static JsonArray Arr(IEnumerable<string> xs) => new(xs.Select(x => (JsonNode?)JsonValue.Create(x)).ToArray());

    /// 有值才放（Swift 的 encodeIfPresent）
    public static void Put(this JsonObject o, string k, string? v) { if (v != null) o[k] = v; }
    public static void Put(this JsonObject o, string k, int? v) { if (v != null) o[k] = v.Value; }
    public static void Put(this JsonObject o, string k, DateTime? v) { if (v != null) o[k] = Iso(v.Value); }
}

/// Swift 字串語意的對照（Swift 的 count／prefix 算的是字（grapheme），C# 的 Length 是 UTF-16 單位）
static class SwiftText
{
    public static int Count(string s) => new StringInfo(s).LengthInTextElements;

    public static string Prefix(string s, int n)
    {
        var si = new StringInfo(s);
        return si.LengthInTextElements <= n ? s : si.SubstringByTextElements(0, n);
    }

    /// .whitespaces：空白類（Zs）＋tab，不含換行
    static bool IsSpace(char c) => c == '\t' || CharUnicodeInfo.GetUnicodeCategory(c) == UnicodeCategory.SpaceSeparator;
    public static string TrimSpaces(string s)
    {
        int a = 0, b = s.Length;
        while (a < b && IsSpace(s[a])) a++;
        while (b > a && IsSpace(s[b - 1])) b--;
        return s[a..b];
    }

    /// Character.isWhitespace 切開、去掉空的
    public static string[] Words(string s) =>
        s.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
}
