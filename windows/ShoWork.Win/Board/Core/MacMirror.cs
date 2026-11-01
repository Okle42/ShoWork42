using System.Collections;
using System.Reflection;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ShoWork;

// Mac 版 SceneDump.json（Swift Mirror 通用編碼）的 C# 對照（11-02 P8）：Windows 推給 3D 網頁的 office2 JSON 跟 Mac bench dump 出來的
// bench/mac-input.json 同一個形狀，網頁的 JS 照那個形狀寫。規則照 Swift 版：
//   struct／class    ＝ 儲存屬性（C# 有 setter 的屬性與公開欄位；get-only 計算屬性不算），名字第一個字母小寫（FloorNo → floorNo）
//   enum（沒有附帶值）＝ case 名稱字串（C# 成員名第一個字母小寫：LightRain → lightRain、app_studio 照原樣）
//   enum（有附帶值）  ＝ {"$case": 名稱, "$value": 內容}（IMacEnum）
//   Optional nil      ＝ null；Date ＝ 1970 起的秒數（小數 3 位）；Double ＝ 小數 6 位；SIMD ＝ 陣列（小數 4 位，見 Vec3）
//   Dictionary        ＝ 物件；Set ＝ 排序過的陣列
// 名字跟 Swift 對不上的用 [MacName]；Swift 沒有、Windows 才有的欄位用 [MacSkip]。

[AttributeUsage(AttributeTargets.Field | AttributeTargets.Property)]
public sealed class MacNameAttribute : Attribute
{
    public string Name { get; }
    public MacNameAttribute(string name) { Name = name; }
}

[AttributeUsage(AttributeTargets.Field | AttributeTargets.Property)]
public sealed class MacSkipAttribute : Attribute { }

/// Swift 有附帶值的 enum（例如 WanderSpot.cafe(slot: 0)）：Value＝null 時只寫 case 名稱
public interface IMacEnum
{
    string Case { get; }
    object? Value { get; }
}

/// 自己決定怎麼編碼（BoardCard 這種 Windows 欄位跟 Mac 不一樣的）
public interface IMacMirror
{
    JsonNode? Mirror();
}

/// SIMD3<Double>／SIMD3<Float>：Mirror 寫成 [x, y, z]、小數 4 位（SceneDump.v3）
public readonly record struct Vec3(double X, double Y, double Z) : IMacMirror
{
    public JsonNode? Mirror() => new JsonArray(MacMirror.R(X), MacMirror.R(Y), MacMirror.R(Z));
    public static Vec3 operator +(Vec3 a, Vec3 b) => new(a.X + b.X, a.Y + b.Y, a.Z + b.Z);
    public static Vec3 operator -(Vec3 a, Vec3 b) => new(a.X - b.X, a.Y - b.Y, a.Z - b.Z);
    public static Vec3 operator *(Vec3 a, double k) => new(a.X * k, a.Y * k, a.Z * k);
    public static Vec3 operator *(Vec3 a, Vec3 b) => new(a.X * b.X, a.Y * b.Y, a.Z * b.Z);
    public static Vec3 operator /(Vec3 a, double k) => new(a.X / k, a.Y / k, a.Z / k);
    public static Vec3 Repeating(double v) => new(v, v, v);
}

public static class MacMirror
{
    /// SceneDump.r：Swift 的 rounded()＝四捨五入（遠離 0）
    public static double R(double x, double p = 10000) => double.IsFinite(x) ? Math.Round(x * p, MidpointRounding.AwayFromZero) / p : 0;

    /// Date → 1970 起的秒數（Kind＝Unspecified 當 UTC：Windows 這邊的時間一律存 UTC）
    public static double Seconds(DateTime d)
    {
        var u = d.Kind == DateTimeKind.Local ? d.ToUniversalTime() : DateTime.SpecifyKind(d, DateTimeKind.Utc);
        return (u - DateTime.UnixEpoch).TotalSeconds;
    }
    public static DateTime FromSeconds(double s) => DateTime.UnixEpoch.AddTicks((long)Math.Round(s * TimeSpan.TicksPerSecond));

    /// C# 名稱 → Swift 名稱（第一個字母小寫）
    public static string Camel(string s) => s.Length == 0 || char.IsLower(s[0]) ? s : char.ToLowerInvariant(s[0]) + s[1..];

    public static JsonNode? Encode(object? v, int depth = 0)
    {
        if (depth > 40) return JsonValue.Create("<deep>");
        switch (v)
        {
            case null: return null;
            case IMacMirror m: return m.Mirror();
            case IMacEnum e: return e.Value == null ? JsonValue.Create(e.Case) : new JsonObject { ["$case"] = e.Case, ["$value"] = Encode(e.Value, depth + 1) };
            case string s: return JsonValue.Create(s);
            case char c: return JsonValue.Create(c.ToString());
            case bool b: return JsonValue.Create(b);
            case Enum en: return JsonValue.Create(Camel(en.ToString()));
            case DateTime d: return JsonValue.Create(R(Seconds(d), 1000));
            case DateTimeOffset dto: return JsonValue.Create(R(dto.ToUnixTimeMilliseconds() / 1000.0, 1000));
            case double x: return JsonValue.Create(R(x, 1e6));
            case float f: return JsonValue.Create(R(f, 1e6));
            case decimal m: return JsonValue.Create(R((double)m, 1e6));
            case int or long or short or byte or sbyte or uint or ushort or ulong: return JsonValue.Create(Convert.ToInt64(v));
            case JsonNode n: return n.DeepClone();
            case BoardCard bc: return CardMirror.Of(bc);          // Windows 的 BoardCard 欄位跟 Mac 不完全一樣：照 Mac 的 28 個欄位寫
        }
        var t = v.GetType();
        if (v is IDictionary dict)
        {
            var o = new JsonObject();
            foreach (DictionaryEntry kv in dict)
            {
                var k = kv.Key is Enum ek ? Camel(ek.ToString()) : kv.Key?.ToString() ?? "";
                o[k] = Encode(kv.Value, depth + 1);
            }
            return o;
        }
        if (IsSet(t))
        {
            var items = ((IEnumerable)v).Cast<object?>().Select(x => Encode(x, depth + 1)).ToList();
            var a = new JsonArray();
            foreach (var x in items.OrderBy(x => x?.ToJsonString() ?? "null", StringComparer.Ordinal)) a.Add(x);
            return a;
        }
        if (v is IEnumerable list)
        {
            var a = new JsonArray();
            foreach (var x in list) a.Add(Encode(x, depth + 1));
            return a;
        }
        var obj = new JsonObject();
        foreach (var (name, get) in Members(t))
        {
            if (obj.ContainsKey(name)) continue;
            obj[name] = Encode(get(v), depth + 1);
        }
        return obj;
    }

    static bool IsSet(Type t) => t.GetInterfaces().Any(i => i.IsGenericType && i.GetGenericTypeDefinition() == typeof(ISet<>));

    static readonly Dictionary<Type, List<(string, Func<object, object?>)>> cache = new();
    static List<(string, Func<object, object?>)> Members(Type t)
    {
        lock (cache)
        {
            if (cache.TryGetValue(t, out var m)) return m;
            m = new();
            foreach (var f in t.GetFields(BindingFlags.Public | BindingFlags.Instance))
            {
                if (f.GetCustomAttribute<MacSkipAttribute>() != null) continue;
                m.Add((f.GetCustomAttribute<MacNameAttribute>()?.Name ?? Camel(f.Name), f.GetValue));
            }
            foreach (var p in t.GetProperties(BindingFlags.Public | BindingFlags.Instance))
            {
                if (!p.CanWrite || p.GetIndexParameters().Length > 0 || p.GetCustomAttribute<MacSkipAttribute>() != null) continue;
                if (p.Name == "EqualityContract") continue;
                m.Add((p.GetCustomAttribute<MacNameAttribute>()?.Name ?? Camel(p.Name), p.GetValue));
            }
            cache[t] = m;
            return m;
        }
    }

    static readonly JsonSerializerOptions Out = new() { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };
    /// 整份 JSON（中文不跳脫，跟 Mac JSONSerialization 一樣直接寫 UTF-8）
    public static string Json(JsonNode? n) => n?.ToJsonString(Out) ?? "null";
}
