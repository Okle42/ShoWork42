using System.IO.Pipes;
using System.Security.Principal;
using System.Text;
using System.Text.Json;

namespace ShoWork;

/// Stamp = when the AI started this hook (FILETIME of the hook shell), 0 = unknown.
public readonly record struct WireMessage(WorkEvent Event, string Agent, int Pid, long Stamp = 0);

/// Named pipe \\.\pipe\ShoWork42-<SID>, the Windows counterpart of the Mac agent.sock (0600):
/// CurrentUserOnly puts an ACL on it that admits only this user. The first instance is created with
/// FirstPipeInstance, so a second agent (or anyone squatting on the name) makes Start() fail.
sealed class PipeServer
{
    public static string Name => Wire.PipeName(WindowsIdentity.GetCurrent().User!.Value);

    readonly Action<WireMessage> post;          // called on a pool thread; must marshal to the UI thread itself

    public PipeServer(Action<WireMessage> post) => this.post = post;

    /// false ⇒ the name is taken (another agent is running).
    public bool Start()
    {
        NamedPipeServerStream first;
        try { first = Create(firstInstance: true); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return false; }
        _ = Loop(first);
        return true;
    }

    static NamedPipeServerStream Create(bool firstInstance) =>
        new(Name, PipeDirection.In, NamedPipeServerStream.MaxAllowedServerInstances, PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly | (firstInstance ? PipeOptions.FirstPipeInstance : 0), 0, 4096);

    async Task Loop(NamedPipeServerStream s)
    {
        while (true)
        {
            try
            {
                await s.WaitForConnectionAsync().ConfigureAwait(false);
                var next = Create(firstInstance: false);       // accept the next hook while this one is read
                _ = Serve(s);
                s = next;
            }
            catch (Exception e)
            {
                Log.Note($"PIPE {e.GetType().Name}: {e.Message}");
                s.Dispose();
                await Task.Delay(200).ConfigureAwait(false);
                try { s = Create(firstInstance: false); } catch { }
            }
        }
    }

    async Task Serve(NamedPipeServerStream s)
    {
        using (s)
        {
            var buf = new byte[1024];
            int n = 0;
            using var cts = new CancellationTokenSource(1000);  // a client that never finishes its line
            try
            {
                while (n < buf.Length)
                {
                    int r = await s.ReadAsync(buf.AsMemory(n), cts.Token).ConfigureAwait(false);
                    if (r == 0) break;
                    n += r;
                    if (Array.IndexOf(buf, (byte)'\n', 0, n) >= 0) break;
                }
            }
            catch { return; }
            if (Parse(buf.AsSpan(0, n)) is { } m) post(m);
        }
    }

    /// Never trust the line: a known event, a boring agent name, a positive pid, protocol v1.
    public static WireMessage? Parse(ReadOnlySpan<byte> line)
    {
        try
        {
            int nl = line.IndexOf((byte)'\n');
            if (nl >= 0) line = line[..nl];
            using var d = JsonDocument.Parse(line.ToArray());
            var r = d.RootElement;
            if (r.GetProperty("v").GetInt32() != 1) return null;
            var ev = StateMachine.ParseEvent(r.GetProperty("event").GetString() ?? "");
            var agent = r.GetProperty("agent").GetString() ?? "";
            var pid = r.GetProperty("pid").GetInt32();
            if (ev == null || !Wire.ValidAgent(agent) || pid <= 0) return null;
            var stamp = r.TryGetProperty("t", out var t) && t.TryGetInt64(out var tv) && tv > 0 ? tv : 0;
            return new WireMessage(ev.Value, agent, pid, stamp);
        }
        catch { return null; }
    }

    public static string Describe(WireMessage m) =>
        $"{m.Agent} pid={m.Pid} {m.Event.ToString().ToLowerInvariant()}{(m.Stamp == 0 ? "" : $" hook@{DateTime.FromFileTime(m.Stamp):HH:mm:ss.fff}")}";
}
