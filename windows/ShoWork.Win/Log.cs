namespace ShoWork;

/// SHOWORK_DEBUG=1 ⇒ %LOCALAPPDATA%\ShoWork42\agent.log (same idea as the Mac agent.log)
static class Log
{
    static readonly string? path = Environment.GetEnvironmentVariable("SHOWORK_DEBUG") == "1"
        ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ShoWork42", "agent.log") : null;

    public static void Note(string s)
    {
        if (path == null) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.AppendAllText(path, $"[{DateTime.Now:HH:mm:ss.fff}] {s}{Environment.NewLine}");
        }
        catch { }                      // logging must never break the glow
    }
}
