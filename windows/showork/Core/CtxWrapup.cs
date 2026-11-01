using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ShoWork.Hooks;

// Stop hook：context 超過戰情中心門檻時，攔住這次停止、請 AI 收尾（Mac 的 ~/.claude/scripts/hook_ctx_wrapup.py 逐行移植；
// Windows 不一定有 Python，所以做進 showork.exe：`showork ctx-wrapup`）。
// 同一個 session：收過後又多 StepTok 再收一次；壓縮後掉回門檻下就重新上膛。
//   • ctx 讀狀態列（`showork statusline`）寫的 ~/.claude/cache/ctx/<sid>.json（無頭 claude -p 沒有狀態列 ⇒ 不會觸發）
//   • 門檻／開關讀 board\prefs.json：board.ctxTokens（250k–1000k，預設 250k）、board.autoWrapUp（預設開）
//   • 送過就寫 ~/.claude/cache/ctx_wrapup/<sid>，戰情中心看這個檔顯示「已請它收尾」
//   • 收尾最後一步是 `showork card --kind wrapup`：戰情中心等它停下自動 /clear、新 context 自動接手（Handover.cs）
//   • SHOWORK_TEST_CTX＝測試用假 ctx，token 數（例如 300000 或 300k；只有帶這個環境變數啟動的 claude 才有）
static class CtxWrapup
{
    public static readonly TimeSpan Stale = TimeSpan.FromMinutes(30);   // 狀態列太久沒更新的 ctx 不採信
    public const int StepTok = 150_000;                                  // 收尾過後又多用 150k 才再收一次

    static string CtxDir => Path.Combine(HookPaths.ClaudeDir, "cache", "ctx");
    static string MarkDir => Path.Combine(HookPaths.ClaudeDir, "cache", "ctx_wrapup");
    static string LogPath => Path.Combine(HookPaths.ClaudeDir, "logs", "ctx_wrapup.log");

    static void Log(string msg, DateTime now) => HookJson.AppendLine(LogPath, $"{now.ToLocalTime():yyyy-MM-dd HH:mm:ss} {msg}");

    static double? Num(JsonNode? o, string k) => o is JsonObject j && j[k] is JsonValue v && v.GetValueKind() == JsonValueKind.Number ? v.GetValue<double>() : null;

    /// 300000、300k、1.2m 都收
    public static int? ParseTestCtx(string? s)
    {
        var t = s?.Trim().ToLowerInvariant();
        if (string.IsNullOrEmpty(t)) return null;
        double mul = t.EndsWith('k') ? 1000 : t.EndsWith('m') ? 1_000_000 : 1;
        if (mul != 1) t = t[..^1];
        return double.TryParse(t, NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? (int)(v * mul) : null;
    }

    /// stdin＝Stop hook JSON；回傳要印的 hook 輸出（null＝放它停）
    public static string? Run(string? stdin, string showork, string? testCtx, DateTime now)
    {
        if (HookJson.Parse(stdin) is not JsonObject d) return null;
        var sid = d.Str("session_id") ?? "";
        if (sid.Length == 0 || d.Bool("stop_hook_active")) return null;
        if (!ContextGuard.AutoWrapUp) return null;
        var mark = Path.Combine(MarkDir, sid);
        var c = HookJson.ReadObject(Path.Combine(CtxDir, sid + ".json"));
        if (c == null && testCtx == null) return null;
        double used = Num(c, "used_percentage") ?? 0;     // 只拿來寫 log
        double? tok = Num(c, "total_input_tokens");
        double at = Num(c, "at") ?? 0;
        double nowSec = (now - DateTime.UnixEpoch).TotalSeconds;
        if (testCtx != null) { tok = ParseTestCtx(testCtx); at = nowSec; }  // 測試 session（假的 ctx）
        if (tok is not { } tk || nowSec - at > Stale.TotalSeconds) return null;
        int t = (int)tk, lim = ContextGuard.TokenLimit;
        int? lastTok = HookJson.ReadObject(mark) is { } m ? (int)(Num(m, "tokens") ?? 0) : null;
        if (t < lim)
        {
            if (lastTok != null)       // 壓縮過、掉回門檻下 ⇒ 重新上膛，之後再滿會再收一次
            {
                try { File.Delete(mark); } catch { }
                Log($"{sid} ctx {t / 1000}k 低於門檻 {lim / 1000}k（壓縮過）→ 重新上膛", now);
            }
            return null;
        }
        if (lastTok != null && t < lastTok + StepTok) return null;     // 長時間工作：比上次收尾又多 150k 才再收
        var cwd = d.Str("cwd") ?? "";
        HookJson.WriteAtomic(mark, HookJson.Text(new JsonObject { ["at"] = nowSec, ["ctx"] = used, ["tokens"] = t, ["cwd"] = cwd }));
        bool again = lastTok != null;
        var pct = used != 0 ? $"（{used:0}%）" : "";
        Log($"{sid} ctx {t / 1000}k{pct}≥ {lim / 1000}k → 請它{(again ? "再次" : "")}收尾（{cwd}）", now);
        var head = again ? $"上次收尾在 {lastTok / 1000}k，之後又做了不少，" : "";
        var b1 = B1Talk.WrapupNote(showork, B1Board.All());
        var reason = $"【AI工作戰情中心】context 已用 {t / 1000}k{pct}，{head}請收尾：①把目前該存的進度 commit；"
            + "②這個 repo 的規則允許才 push（規定不准 push、要先審或有客戶資料的就不要推，回報原因）；"
            + "③更新交接文件（寫清楚未完成工作與下一步）與記憶；"
            + b1.TrimEnd('。') + "；"
            + $"⑤最後發收尾卡：`\"{showork}\" card --kind wrapup --handoff <交接文件絕對路徑> "
            + "--doing <任務> --summary \"<一句接手重點>\"`（有派工單就加 --task <單號>），發完就停下、不要再做別的事："
            + "戰情中心看到你停下來會自動 /clear，新 context 會自動讀這份交接接手（英文名、派工單沿用）。"
            + "**不要叫使用者 /clear**。如果剛才那則回覆是在問使用者問題，發完收尾卡再把問題完整問一次（這樣就不會自動 /clear）。";
        return HookJson.Text(new JsonObject { ["decision"] = "block", ["reason"] = reason });
    }
}
