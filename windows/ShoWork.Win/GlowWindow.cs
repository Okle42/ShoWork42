using System.Drawing;
using System.Runtime.InteropServices;
using static ShoWork.Native;

namespace ShoWork;

/// The glow around one target window: click-through, never-activated layered windows kept directly BELOW
/// the target in z-order, so the target covers the middle and only the light around it shows (same idea
/// as the Mac version's `order(.below, relativeTo:)`).
///
/// A still glow (breathing, or any style with animation effects off) is one window the size of the target
/// plus the glow, drawn once per size/look change; breathing then only changes the layer's constant alpha
/// and nothing is kept in memory. A moving style is four strips (top, bottom, left, right — this Form is the
/// first): it keeps its pixels between frames, and for a large window the covered middle would be most of
/// the memory and of each frame's copy to the screen. It redraws at most 30 fps (GlowArt.Fps), only while
/// visible; its buffers are freed while it is hidden.
sealed class GlowWindow : Form
{
    public IntPtr Target { get; }
    public WorkState State { get; private set; }

    GlowArt? art;                             // pixels for the current size/look; null = needs a redraw
    Strip[] strips = Array.Empty<Strip>();    // [0] wraps this Form's own handle
    RECT at;                                  // where the target was when the strips were placed
    byte alpha = 255;
    readonly System.Windows.Forms.Timer anim = new();
    bool shown;

    public GlowWindow(IntPtr target, WorkState state)
    {
        Target = target;
        State = state;
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        anim.Tick += (_, _) => Frame();
    }

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= Strip.ExStyle;
            return cp;
        }
    }

    /// The colour the user picked for a state (tray icon, island).
    public static Color ColorOf(WorkState s) => s == WorkState.Idle ? Color.Transparent : GlowSettings.Shared.Look(s).Color;

    public void SetState(WorkState s)
    {
        if (s == State) return;
        State = s;
        Restyle();
    }

    /// Settings changed (colour, style, brightness…): redraw with the new look.
    public void Restyle()
    {
        Drop();
        Sync();
    }

    /// Put the glow exactly around the target and directly below it. Called on move/resize/reorder
    /// events and by the watchdog. Hides itself while the target is minimised, hidden or cloaked.
    public void Sync()
    {
        if (IsDisposed) return;
        if (!IsWindow(Target)) { Close(); return; }
        if (State == WorkState.Idle || IsIconic(Target) || !IsWindowVisible(Target) || IsCloaked(Target))
        {
            Log.Note($"HIDE {Target} idle={State == WorkState.Idle} iconic={IsIconic(Target)} visible={IsWindowVisible(Target)} cloaked={IsCloaked(Target)}");
            Hide(true);
            return;
        }
        var look = GlowSettings.Shared.Look(State);
        var r = VisibleRect(Target);
        var size = new Size(r.Right - r.Left, r.Bottom - r.Top);
        if (size.Width <= 0 || size.Height <= 0) { Hide(true); return; }
        float s = GetDpiForWindow(Target) / 96f;
        bool still = GlowSettings.ReduceMotion;
        if (art == null || art.Target != size || art.S != s || art.Look != look || art.Still != still || strips.Length == 0)
        {
            art?.Dispose();
            art = new GlowArt(look, size, s, still: still);
            Build();
            at = default;
        }
        if (!at.Equals(r) || !shown || !StackedRight) Place(r);
        if (art.Fps > 0 || art.Breathes)
        {
            anim.Interval = art.Fps > 0 ? 1000 / art.Fps : 33;          // ~30 fps is plenty for a 3.2 s breath
            if (!anim.Enabled) anim.Start();
        }
        else anim.Stop();
    }

    /// (Re)create the strip windows for the art's parts and draw the first frame.
    void Build()
    {
        var parts = art!.Parts;
        if (strips.Length != parts.Length)
        {
            foreach (var st in strips) st.Dispose();                     // [0] only frees its pixels: the Form stays
            strips = new Strip[parts.Length];
            strips[0] = new Strip(Handle);
            for (int i = 1; i < parts.Length; i++) strips[i] = new Strip(IntPtr.Zero);
        }
        for (int i = 0; i < parts.Length; i++) strips[i].Alloc(parts[i].Size);
        alpha = art.AlphaAt(Now);
        DrawFrame();
        // a still glow keeps only its description, not its maps or pixels: the layered windows hold the image
        if (art.Fps == 0) { foreach (var st in strips) st.Free(); art.Release(); }
    }

    unsafe void DrawFrame()
    {
        long t0 = System.Diagnostics.Stopwatch.GetTimestamp();
        var bits = new uint*[strips.Length];
        for (int i = 0; i < strips.Length; i++) bits[i] = strips[i].Bits;
        art!.Draw(Now, bits);
        long t1 = System.Diagnostics.Stopwatch.GetTimestamp();
        for (int i = 0; i < strips.Length; i++) strips[i].Push(art.Parts[i].Size, alpha);
        // SHOWORK_DEBUG: what a frame costs (drawing vs handing it to DWM), every 300 frames
        drawTicks += t1 - t0; pushTicks += System.Diagnostics.Stopwatch.GetTimestamp() - t1;
        if (frames++ % 300 == 0)
        {
            double f = System.Diagnostics.Stopwatch.Frequency;
            if (frames > 1)
                Log.Note($"PERF {Target} {art.Style} {art.Parts.Sum(p => p.Width * p.Height)} px: draw {drawTicks * 1000 / f / 300:0.00} ms, push {pushTicks * 1000 / f / 300:0.00} ms per frame, {300 * f / (t0 - perfStart):0.0} fps");
            drawTicks = pushTicks = 0;
            perfStart = t0;
        }
    }
    long drawTicks, pushTicks, frames, perfStart;

    /// Screen position of every strip, and z-order: directly below the target, one after another.
    void Place(RECT r)
    {
        at = r;
        var hdwp = BeginDeferWindowPos(strips.Length);
        var after = Target;
        for (int i = 0; i < strips.Length; i++)
        {
            var p = art!.Parts[i];
            // hWndInsertAfter = previous ⇒ right after (= below) it
            hdwp = DeferWindowPos(hdwp, strips[i].Hwnd, after, r.Left - art.Pad + p.Left, r.Top - art.Pad + p.Top, p.Width, p.Height,
                                  SWP_NOACTIVATE | SWP_SHOWWINDOW);
            after = strips[i].Hwnd;
        }
        if (hdwp != IntPtr.Zero) EndDeferWindowPos(hdwp);
        shown = true;
        Visible = true;
        Log.Note($"SHOW {Target} rect={r.Left},{r.Top},{r.Right},{r.Bottom} pad={art!.Pad} style={art.Style} parts={strips.Length} below={StackedRight}");
    }

    void Hide(bool freeMemory)
    {
        anim.Stop();
        if (shown)
        {
            foreach (var st in strips) SetWindowPos(st.Hwnd, IntPtr.Zero, 0, 0, 0, 0, SWP_HIDEWINDOW | SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
            shown = false;
            Visible = false;
        }
        // a moving style's maps and buffers are rebuilt when it shows again; a still one is kept (nothing to free)
        if (freeMemory && art is { Fps: > 0 }) Drop();
    }

    /// Forget the art and pixel buffers; the next Sync draws afresh.
    void Drop()
    {
        foreach (var st in strips) st.Free();
        art?.Dispose();
        art = null;
    }

    /// Are the strips still the first visible windows below the target? (a few GetWindow calls)
    public bool StackedRight
    {
        get
        {
            if (!shown) return true;
            var h = Target;
            foreach (var st in strips)
            {
                h = NextVisibleBelow(h);
                if (h != st.Hwnd) return false;
            }
            return true;
        }
    }

    static double Now => Environment.TickCount64 / 1000.0;

    void Frame()
    {
        if (art == null || !shown) { anim.Stop(); return; }
        if (art.Fps > 0) { DrawFrame(); return; }
        var a = art.AlphaAt(Now);                               // breathing: only the constant alpha changes
        if (a == alpha) return;
        alpha = a;
        foreach (var st in strips) st.Blend(alpha);
    }

    protected override void WndProc(ref Message m)
    {
        // animation effects switched on/off in Settings: follow at once (a broadcast every top-level window gets)
        if (m.Msg == 0x001A /*WM_SETTINGCHANGE*/ && m.WParam == GlowSettings.SPI_SETCLIENTAREAANIMATION && shown) BeginInvoke(Restyle);
        base.WndProc(ref m);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            anim.Dispose();
            art?.Dispose();
            foreach (var st in strips) st.Dispose();
            strips = Array.Empty<Strip>();
        }
        base.Dispose(disposing);
    }

    [DllImport("user32.dll")] static extern IntPtr BeginDeferWindowPos(int n);
    [DllImport("user32.dll")] static extern IntPtr DeferWindowPos(IntPtr hdwp, IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool EndDeferWindowPos(IntPtr hdwp);

    /// One layered, click-through, never-activated window and the DIB it is drawn from. The first strip is
    /// the Form's own window; the others are bare native windows (much lighter than Forms).
    sealed unsafe class Strip : NativeWindow, IDisposable
    {
        public const int ExStyle = WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
        readonly bool own;
        IntPtr dc, bmp, old;
        Size size;
        public uint* Bits { get; private set; }
        public IntPtr Hwnd { get; }

        public Strip(IntPtr existing)
        {
            if (existing != IntPtr.Zero) { Hwnd = existing; return; }
            own = true;
            CreateHandle(new CreateParams { Style = unchecked((int)0x80000000) /*WS_POPUP*/, ExStyle = ExStyle });
            Hwnd = Handle;
        }

        /// A top-down 32-bit DIB section the size of the strip (zeroed = transparent).
        public void Alloc(Size s)
        {
            if (Bits != null && s == size) return;
            Free();
            size = s;
            var bi = new BITMAPINFOHEADER { biSize = sizeof(BITMAPINFOHEADER), biWidth = s.Width, biHeight = -s.Height, biPlanes = 1, biBitCount = 32 };
            var screen = GetDC(IntPtr.Zero);
            dc = CreateCompatibleDC(screen);
            ReleaseDC(IntPtr.Zero, screen);
            bmp = CreateDIBSection(dc, ref bi, 0, out var bits, IntPtr.Zero, 0);
            Bits = (uint*)bits;
            old = SelectObject(dc, bmp);
        }

        public void Free()
        {
            if (dc == IntPtr.Zero) return;
            SelectObject(dc, old);
            DeleteObject(bmp);
            DeleteDC(dc);
            dc = bmp = IntPtr.Zero;
            Bits = null;
        }

        /// Hand the pixels to the window. Position stays whatever SetWindowPos gave it.
        public void Push(Size s, byte alpha)
        {
            if (dc == IntPtr.Zero) return;
            var sz = new SIZE(s.Width, s.Height);
            var src = new POINT(0, 0);
            var blend = new BLENDFUNCTION { BlendOp = AC_SRC_OVER, SourceConstantAlpha = alpha, AlphaFormat = AC_SRC_ALPHA };
            UpdateLayeredWindowNoMove(Hwnd, IntPtr.Zero, IntPtr.Zero, ref sz, dc, ref src, 0, ref blend, ULW_ALPHA);
        }

        /// blend-only update (no new bitmap, no move) — what breathing uses: nothing is redrawn
        public void Blend(byte alpha)
        {
            var blend = new BLENDFUNCTION { BlendOp = AC_SRC_OVER, SourceConstantAlpha = alpha, AlphaFormat = AC_SRC_ALPHA };
            UpdateLayeredWindowBlend(Hwnd, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 0, ref blend, ULW_ALPHA);
        }

        public void Dispose()
        {
            Free();
            if (own && Handle != IntPtr.Zero) DestroyHandle();
        }

        [StructLayout(LayoutKind.Sequential)]
        struct BITMAPINFOHEADER
        {
            public int biSize, biWidth, biHeight; public short biPlanes, biBitCount;
            public int biCompression, biSizeImage, biXPelsPerMeter, biYPelsPerMeter, biClrUsed, biClrImportant;
        }
        [DllImport("gdi32.dll")] static extern IntPtr CreateDIBSection(IntPtr hdc, ref BITMAPINFOHEADER bi, uint usage, out IntPtr bits, IntPtr section, uint offset);
        [DllImport("user32.dll", EntryPoint = "UpdateLayeredWindow")]
        static extern bool UpdateLayeredWindowNoMove(IntPtr hwnd, IntPtr hdcDst, IntPtr pptDst, ref SIZE psize, IntPtr hdcSrc,
            ref POINT pptSrc, int crKey, ref BLENDFUNCTION pblend, int dwFlags);
    }
}
