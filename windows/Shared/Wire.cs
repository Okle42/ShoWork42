namespace ShoWork;

/// Shared by showork.exe (sender) and ShoWorkAgent.exe (receiver): one line of JSON over a named pipe.
///   {"v":1,"event":"working","agent":"claude","pid":1234,"t":134035392000000000}\n
/// The pid is the AI process (claude.exe). It plays the role of the Mac version's tty: one AI session,
/// one entry; the agent maps it to a window. t = when the AI started the hook (FILETIME, 0 = unknown).
static class Wire
{
    public static readonly string[] Events = { "working", "done", "input", "clear" };

    /// \.\pipe\ShoWork42-<user SID>. SHOWORK_PIPE overrides the name (tests run a private agent).
    public static string PipeName(string sid) =>
        Environment.GetEnvironmentVariable("SHOWORK_PIPE") is { Length: > 0 } p ? p : "ShoWork42-" + sid;

    /// %LOCALAPPDATA%ShoWork42 (state, log, install snapshot). SHOWORK_HOME overrides it for tests.
    public static string SupportDir =>
        Environment.GetEnvironmentVariable("SHOWORK_HOME") is { Length: > 0 } h ? h
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ShoWork42");

    /// Agent names go into JSON and logs verbatim, so keep them boring.
    public static bool ValidAgent(string s) =>
        s.Length is > 0 and <= 32 && s.All(c => c is >= 'a' and <= 'z' or >= '0' and <= '9' or '-' or '_');
}
