using System.Runtime.InteropServices;
using static ShoWork.Native;

namespace ShoWork;

/// Key press or left click ⇒ "the user looked at that window" (clears green), like the Mac ClearWatcher.
/// Low-level hooks see only the event type and where it went: we never look at which key it was.
/// They are installed ONLY while some window is green, so an idle agent sits outside the input path.
/// The callback just notes the window and returns; the work happens after, on the UI thread.
sealed class ClearWatcher
{
    readonly Action<IntPtr> onActivity;      // top-level window the key/click went to
    readonly HookProc keyProc, mouseProc;     // keep the delegates alive while the hooks exist
    IntPtr keyHook, mouseHook;
    long lastTick;
    IntPtr lastWindow;

    public ClearWatcher(Action<IntPtr> onActivity)
    {
        this.onActivity = onActivity;
        keyProc = OnKey;
        mouseProc = OnMouse;
    }

    public bool Active => keyHook != IntPtr.Zero;

    public void Enable(bool on)
    {
        if (on == Active) return;
        if (on)
        {
            var mod = GetModuleHandle(null);
            keyHook = SetWindowsHookEx(WH_KEYBOARD_LL, keyProc, mod, 0);
            mouseHook = SetWindowsHookEx(WH_MOUSE_LL, mouseProc, mod, 0);
            Log.Note($"CLEARWATCH on key={keyHook} mouse={mouseHook}");
        }
        else
        {
            if (keyHook != IntPtr.Zero) UnhookWindowsHookEx(keyHook);
            if (mouseHook != IntPtr.Zero) UnhookWindowsHookEx(mouseHook);
            keyHook = mouseHook = IntPtr.Zero;
            Log.Note("CLEARWATCH off");
        }
    }

    IntPtr OnKey(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0 && (wParam == WM_KEYDOWN || wParam == WM_SYSKEYDOWN)) Note(GetForegroundWindow());
        return CallNextHookEx(keyHook, code, wParam, lParam);
    }

    IntPtr OnMouse(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0 && wParam == WM_LBUTTONDOWN)
        {
            var pt = Marshal.PtrToStructure<POINT>(lParam);          // MSLLHOOKSTRUCT starts with the point
            Note(WindowFromPoint(pt));                                 // glows are click-through, never hit
        }
        return CallNextHookEx(mouseHook, code, wParam, lParam);
    }

    void Note(IntPtr hwnd)
    {
        var root = hwnd == IntPtr.Zero ? IntPtr.Zero : GetAncestor(hwnd, GA_ROOT);
        long now = Environment.TickCount64;
        if (root == lastWindow && now - lastTick < 250) return;     // debounce typing
        lastTick = now;
        lastWindow = root;
        if (root == IntPtr.Zero) return;
        // leave the hook first: Windows drops low-level hooks that keep input waiting
        SynchronizationContext.Current?.Post(_ => onActivity(root), null);
    }
}
