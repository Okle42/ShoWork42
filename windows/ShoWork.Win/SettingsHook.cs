namespace ShoWork;

/// What the tray menu calls for features that live in other parts of the agent (settings window,
/// arranger). Null = not wired: the menu item is shown disabled. Program/Engine set these at startup.
static partial class TrayHooks
{
    /// 「設定…」: open (or bring back) the settings window.
    public static Action? OpenSettings = null;
    /// 「立即排版 (Ctrl+Alt+L)」: arrange the AI windows once, now.
    public static Action? ArrangeNow = null;
    /// 「自動排版」: current value and setter.
    public static Func<bool>? GetAutoArrange = null;
    public static Action<bool>? SetAutoArrange = null;
}
