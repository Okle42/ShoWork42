using System.Text.Json;
using System.Text.Json.Nodes;

namespace ShoWork.Hooks;

// 戰情中心的設定值（Mac 是 UserDefaults suite ai.okle42.showork；Windows 沒有 defaults，放 %LOCALAPPDATA%\ShoWork42\board\prefs.json）。
// 鍵名照 Mac：{"board.ctxTokens": 250000, "board.autoWrapUp": true, "captain.relayCards": true, "captain.alarmMinutes": 30}
// 沒有這個檔＝全用預設。看板 UI（另一個 agent）要調 ctx 門檻時寫同一份檔、同一個鍵。SHOWORK_PREFS 可換路徑（測試用）。
static class Prefs
{
    public static string FilePath => HookPaths.Env("SHOWORK_PREFS") ?? Path.Combine(HookPaths.Board, "prefs.json");

    static JsonObject? Load() => HookJson.ReadObject(FilePath);

    public static double? Number(string key) =>
        Load()?[key] is JsonValue v && v.GetValueKind() == JsonValueKind.Number ? v.GetValue<double>() : null;

    /// 沒設過＝null；true／false 之外也接受 0／1（Mac defaults 讀出來是 "0"／"1"）
    public static bool? Flag(string key) => Load()?[key] is JsonValue v
        ? v.GetValueKind() switch
        {
            JsonValueKind.True => true, JsonValueKind.False => false,
            JsonValueKind.Number => v.GetValue<double>() != 0,
            JsonValueKind.String => v.GetValue<string>() is "1" or "true" ? true : v.GetValue<string>() is "0" or "false" ? false : null,
            _ => null,
        }
        : null;
}

/// ctx 交接門檻（Mac Card.swift 的 ContextGuard）：context 用到幾 token 就交接，250k–1000k，預設 250k
static class ContextGuard
{
    public const int DefaultTokenLimit = 250_000, TokenMin = 250_000, TokenMax = 1_000_000, TokenStep = 10_000;

    public static int TokenLimit => Clamp((int)(Prefs.Number("board.ctxTokens") ?? 0));

    /// 沒設過（0）用預設；超出範圍的舊值拉回 250k–1000k，對齊 10k
    public static int Clamp(int v)
    {
        if (v <= 0) return DefaultTokenLimit;
        int r = (v + TokenStep / 2) / TokenStep * TokenStep;
        return Math.Min(Math.Max(r, TokenMin), TokenMax);
    }

    public static bool AutoWrapUp => Prefs.Flag("board.autoWrapUp") ?? true;
}
