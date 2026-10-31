using System.IO.Pipes;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace ShoWork.Hooks;

// 直接把訊息送進另一個 Claude Code session 的收件匣（Mac 版 Sources/ShoWorkCore/Peer.swift 的移植；跟內建 SendMessage 同一條路）：
//   ~/.claude/sessions/<pid>.json            messagingSocketPath
//   ~/.claude/sessions/<pid>.<hash>.key      {"peerToken": "…"}
//   連上 → 一行 {"type":"auth","token":…} → 一行訊息 JSON，對方不回應。
// Mac 的 messagingSocketPath 是 Unix socket（/tmp/cc-socks/<pid>.sock）。Windows 版 Claude Code 這欄長什麼樣子還沒在真機看過：
//   \\.\pipe\… 或 //./pipe/… ⇒ 當 named pipe 連；其他 ⇒ 當 Unix socket 檔（.NET 8 在 Windows 10 1803+ 也支援 AF_UNIX）。
// ⚠ Windows 這兩條都沒在真機驗證過。連不上就回錯誤：呼叫端不標 delivered，單子留在收件匣，新隊長跑 showork captain 會看到（Mac 也是這個退路）。
// Mac 的 Handover.shouldHold（收尾中先暫存）Windows 沒有自動交接，不做。
static class Peer
{
    /// 開著的 session（行程還在）
    public static List<PeerSession> Sessions() => PeerSession.Live();

    /// 名字、英文短名、sessionId 或它的開頭都可以；短名有兩個活的同名就回 null
    public static PeerSession? Find(string who) => Resolve(who).Ok;

    public static (PeerSession? Ok, string? Error) Resolve(string who)
    {
        var all = Sessions();
        var nick = NicknameStore.All().ToDictionary(kv => kv.Key, kv => kv.Value.Name);
        var hits = ShortName.Match(who, all.Select(r => (r.SessionId, r.Name)).ToList(), nick);
        var rs = hits.Select(sid => all.First(r => r.SessionId == sid)).ToList();
        return rs.Count switch
        {
            1 => (rs[0], null),
            0 => (null, $"找不到開著的 session「{who}」"),
            _ => (null, $"「{who}」有 {rs.Count} 個開著的 session，請用全名或 sessionId：" + string.Join("、", rs.Select(r => $"{r.Name ?? "?"}（{r.SessionId[..Math.Min(8, r.SessionId.Length)]}）"))),
        };
    }

    /// 訊息本體（純函式，測試用）。鍵照字母排（同 Mac 的 .sortedKeys）
    public static List<string> Lines(string token, string text, string fromName, string? replyTo, string id)
    {
        static string Esc(string s) => s.Replace("&", "&amp;").Replace("\"", "&quot;").Replace("<", "&lt;");
        var from = "uds:" + (replyTo ?? "");
        var body = $"<cross-session-message from=\"{Esc(from)}\" from-name=\"{Esc(fromName)}\">\n{text}\n</cross-session-message>";
        var auth = HookJson.Write(w => { w.WriteStartObject(); w.WriteString("token", token); w.WriteString("type", "auth"); w.WriteEndObject(); });
        var msg = HookJson.Write(w =>
        {
            w.WriteStartObject();
            w.WriteString("from", from);
            w.WritePropertyName("message");
            w.WriteStartObject(); w.WriteString("content", body); w.WriteString("role", "user"); w.WriteEndObject();
            w.WriteNumber("msgV", 1);
            w.WriteString("msg_id", id);
            w.WriteString("priority", "next");
            w.WriteString("type", "user");
            w.WriteEndObject();
        });
        return new() { auth, msg };
    }

    /// 收件鑰匙：sessions\<pid>.<hash>.key 的 peerToken
    static string? Token(PeerSession r)
    {
        var f = HookJson.Files(PeerSession.Dir, $"{r.Pid}.*.key").FirstOrDefault();
        return f == null ? null : HookJson.ReadObject(f).Str("peerToken");
    }

    /// 送出；成功回傳訊息 id
    public static (string? Id, string? Error) Send(PeerSession r, string text, string fromName, string? replyTo = null)
    {
        if (r.MessagingSocketPath is not { Length: > 0 } path) return (null, $"{r.Name ?? r.SessionId} 沒有收件匣（版本太舊或是背景 session）");
        if (Token(r) is not { } token) return (null, $"找不到 {r.Name ?? r.SessionId} 的收件鑰匙");
        var id = Guid.NewGuid().ToString().ToLowerInvariant();
        var data = Encoding.UTF8.GetBytes(string.Concat(Lines(token, text, fromName, replyTo, id).Select(l => l + "\n")));
        try
        {
            if (PipeName(path) is { } pipe)
            {
                using var p = new NamedPipeClientStream(".", pipe, PipeDirection.Out);
                p.Connect(2000);
                p.Write(data);
                p.Flush();
            }
            else
            {
                using var s = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified) { SendTimeout = 2000 };
                var t = s.ConnectAsync(new UnixDomainSocketEndPoint(path));
                if (!t.Wait(2000)) return (null, $"連不上 {r.Name ?? r.SessionId} 的收件匣（逾時）");
                int n = s.Send(data);
                if (n != data.Length) return (null, $"只送出 {n}/{data.Length} bytes");
            }
            Thread.Sleep(150);                // 讓對方讀完再關（Mac 實測 SendMessage 也是送完就關）
            return (id, null);
        }
        catch (Exception e)
        {
            return (null, $"連不上 {r.Name ?? r.SessionId} 的收件匣（{(e is AggregateException a ? a.InnerException?.Message : e.Message)}）");
        }
    }

    /// \\.\pipe\name 或 //./pipe/name ⇒ name；不是 named pipe ⇒ null
    public static string? PipeName(string path)
    {
        var p = path.Replace('/', '\\');
        const string pre = @"\\.\pipe\";
        return p.StartsWith(pre, StringComparison.OrdinalIgnoreCase) && p.Length > pre.Length ? p[pre.Length..] : null;
    }
}
