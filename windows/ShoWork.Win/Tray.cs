using System.Drawing.Drawing2D;
using System.Drawing.Text;
using static ShoWork.Native;

namespace ShoWork;

/// System tray icon — the Windows home of the "dynamic island": a dot in the most urgent colour with the
/// number of AI sessions in it (the Mac menu bar's ●N). Left click opens the island flyout, a session that
/// finishes or asks pops the pill, right click opens the menu. Icons are redrawn only when the counts
/// change; the only animation is a slow pulse (precomputed frames, ~3 fps) while something is red.
sealed class Tray : IDisposable
{
    static readonly int[] PulseSeq = { 0, 1, 2, 3, 2, 1 };

    readonly Engine engine;
    readonly NotifyIcon icon = new();
    readonly List<(IntPtr h, Icon icon)> frames = new();
    // the dot's colour is part of what is shown: the settings page can change it without any count changing
    (int working, int done, int input, Color color) shown = (-1, -1, -1, Color.Empty);
    System.Windows.Forms.Timer? pulse, coalesce, trim;
    int pulseAt;
    IslandFlyout? flyout;
    long flyoutClosedAt;
    IslandPill? pill;
    readonly List<SessionView> pending = new(), onPill = new();

    public Tray(Engine engine, Action reload, Action quit)
    {
        this.engine = engine;
        // the menu (ToolStrip) is a big part of WinForms: build it the first time someone right-clicks
        icon.MouseDown += (_, e) => { if (e.Button == MouseButtons.Right && icon.ContextMenuStrip == null) icon.ContextMenuStrip = Menu(reload, quit); };
        icon.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) ToggleFlyout(); };
        engine.StateChanged += OnStateChanged;
        GlowSettings.Shared.Changed += OnSettingsChanged;
        Update(0, 0, 0);
        icon.Visible = true;
    }

    static ContextMenuStrip Menu(Action reload, Action quit)
    {
        var menu = new ContextMenuStrip();
        var settings = new ToolStripMenuItem("設定…", null, (_, _) => TrayHooks.OpenSettings?.Invoke());
        var arrange = new ToolStripMenuItem("立即排版 (Ctrl+Alt+L)", null, (_, _) => TrayHooks.ArrangeNow?.Invoke());
        var auto = new ToolStripMenuItem("自動排版", null, (_, _) => TrayHooks.SetAutoArrange?.Invoke(!(TrayHooks.GetAutoArrange?.Invoke() ?? false)));
        menu.Items.AddRange(new ToolStripItem[] { settings, arrange, auto, new ToolStripSeparator() });
        menu.Items.Add("重新載入", null, (_, _) => reload());
        menu.Items.Add("結束", null, (_, _) => quit());
        // hooks are wired by other parts of the agent; read them each time so late wiring shows up
        menu.Opening += (_, _) =>
        {
            settings.Enabled = TrayHooks.OpenSettings != null;
            arrange.Enabled = TrayHooks.ArrangeNow != null;
            auto.Enabled = TrayHooks.GetAutoArrange != null && TrayHooks.SetAutoArrange != null;
            auto.Checked = TrayHooks.GetAutoArrange?.Invoke() ?? false;
        };
        return menu;
    }

    /// A colour picked in the settings window: redraw now, whatever order the Changed handlers run in.
    void OnSettingsChanged() => Update(shown.working, shown.done, shown.input);

    public void Update(int working, int done, int input)
    {
        var top = input > 0 ? WorkState.Input : done > 0 ? WorkState.Done : working > 0 ? WorkState.Working : WorkState.Idle;
        var color = DotColor(top);
        if (shown == (working, done, input, color)) return;
        shown = (working, done, input, color);
        var old = frames.ToList();
        frames.Clear();
        int n = working + done + input;
        for (int i = 0; i < (top == WorkState.Input ? 4 : 1); i++)
        {
            var h = Draw(n, top, i);
            frames.Add((h, Icon.FromHandle(h)));
        }
        pulseAt = 0;
        icon.Icon = frames[0].icon;
        foreach (var (h, ic) in old) { ic.Dispose(); DestroyIcon(h); }       // after the shell has the new one
        icon.Text = n == 0 ? "ShoWork42：沒有 AI 在工作" : $"ShoWork42\n工作中 {working}・已完成 {done}・等你回答 {input}";
        if (frames.Count > 1)
        {
            if (pulse == null) { pulse = new System.Windows.Forms.Timer { Interval = 300 }; pulse.Tick += (_, _) => Pulse(); }
            pulse.Start();
        }
        else pulse?.Stop();
    }

    void Pulse()
    {
        pulseAt = (pulseAt + 1) % PulseSeq.Length;
        icon.Icon = frames[PulseSeq[pulseAt] % frames.Count].icon;
    }

    static Color DotColor(WorkState top) => top == WorkState.Idle ? Color.FromArgb(0x8E, 0x8E, 0x93) : GlowWindow.ColorOf(top);

    /// Pulse frame 0 is the plain dot; 1–3 fade the red towards a darker red, so the number stays readable.
    static IntPtr Draw(int count, WorkState top, int frame)
    {
        var size = SystemInformation.SmallIconSize.Width;            // 16 at 100 %, 24 at 150 %…
        using var bmp = new Bitmap(size, size);
        using var g = Graphics.FromImage(bmp);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        g.Clear(Color.Transparent);
        var c = DotColor(top);
        if (frame > 0)
        {
            float t = frame * 0.14f;
            c = Color.FromArgb((int)(c.R * (1 - t)), (int)(c.G * (1 - t)), (int)(c.B * (1 - t)));
        }
        using (var b = new SolidBrush(c)) g.FillEllipse(b, 0.5f, 0.5f, size - 1.5f, size - 1.5f);
        if (count > 0)
        {
            var text = count > 9 ? "9+" : count.ToString();
            using var f = new Font("Segoe UI", size * (text.Length > 1 ? 0.42f : 0.58f), FontStyle.Bold, GraphicsUnit.Pixel);
            using var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
            g.DrawString(text, f, Brushes.White, new RectangleF(0, 0, size, size + 1), sf);
        }
        return bmp.GetHicon();
    }

    // MARK: island flyout

    void ToggleFlyout()
    {
        if (flyout != null) { flyout.Close(); return; }
        // clicking the icon while the flyout is open deactivates (closes) it first: that click means "close"
        if (Environment.TickCount64 - flyoutClosedAt < 400) return;
        pill?.Close();
        // same on-screen check as the pill (an auto-hide taskbar can report an off-screen rect); a click falls back to the cursor
        var anchor = TrayPlace.IconRect(icon) is { } r && Screen.AllScreens.Any(s => s.Bounds.IntersectsWith(r))
            ? r : new Rectangle(Cursor.Position, new Size(1, 1));
        flyout = new IslandFlyout(engine, anchor);
        // a modeless form disposes itself on close
        flyout.FormClosed += (_, _) => { flyoutClosedAt = Environment.TickCount64; flyout = null; TrimLater(); };
        flyout.Show();
        Log.Note($"ISLAND open anchor={anchor} bounds={flyout.Bounds}");
    }

    // MARK: pill

    /// Done/input arrive in bursts (several tabs finishing together, done→acknowledged within a moment):
    /// collect for 400 ms, then pop one pill for the most urgent session that is still in that state.
    /// A pill already on screen absorbs later arrivals («+1») instead of a green one replacing a red one.
    void OnStateChanged(SessionView s, WorkState before)
    {
        if (s.State is not (WorkState.Done or WorkState.Input))
        {
            // answered / looked at while waiting or on the pill: it must not keep saying so (or count it in «+N»)
            pending.RemoveAll(p => p.Pid == s.Pid);
            if (pill != null && onPill.RemoveAll(p => p.Pid == s.Pid) > 0) Retarget();
            return;
        }
        pending.RemoveAll(p => p.Pid == s.Pid);
        pending.Add(s);
        if (coalesce == null) { coalesce = new System.Windows.Forms.Timer { Interval = 400 }; coalesce.Tick += (_, _) => Flush(); }
        coalesce.Stop();
        coalesce.Start();
    }

    void Flush()
    {
        coalesce!.Stop();
        var live = engine.Sessions.ToDictionary(x => x.Pid);
        var fg = GetForegroundWindow();
        var fresh = pending.Where(p => p.Window == IntPtr.Zero || p.Window != fg).ToList();
        if (fresh.Count < pending.Count) Log.Note($"PILL skip {pending.Count - fresh.Count}: window in front");
        pending.Clear();
        // fresh views (the window may have resolved meanwhile); still in the state that popped it
        var show = onPill.Concat(fresh).GroupBy(p => p.Pid).Select(g => g.Last())
                         .Where(p => live.TryGetValue(p.Pid, out var cur) && cur.State == p.State).Select(p => live[p.Pid])
                         .Where(p => p.Window == IntPtr.Zero || p.Window != fg).ToList();
        if (fresh.Count == 0 || show.Count == 0 || flyout != null) return;     // the open island already shows it
        var top = show.OrderByDescending(p => StateMachine.Priority(p.State)).ThenByDescending(p => p.Since).First();
        if (pill == null)
        {
            pill = new IslandPill(pid => engine.Sessions.FirstOrDefault(x => x.Pid == pid).Window);
            pill.FormClosed += (_, _) => { pill = null; onPill.Clear(); TrimLater(); };
        }
        onPill.Clear();
        onPill.AddRange(show);
        pill.Pop(top, show.Count - 1, TrayPlace.Anchor(icon));
        Log.Note($"PILL pid={top.Pid} {top.State} +{show.Count - 1} bounds={pill.Bounds}");
    }

    /// A session left the pill: show the most urgent one still waiting, or close it when none is.
    void Retarget()
    {
        var live = engine.Sessions.ToDictionary(x => x.Pid);
        var still = onPill.Where(p => live.TryGetValue(p.Pid, out var cur) && cur.State == p.State).Select(p => live[p.Pid]).ToList();
        onPill.Clear();
        onPill.AddRange(still);
        if (still.Count == 0) { pill!.Close(); return; }
        var top = still.OrderByDescending(p => StateMachine.Priority(p.State)).ThenByDescending(p => p.Since).First();
        pill!.Pop(top, still.Count - 1, TrayPlace.Anchor(icon));
        Log.Note($"PILL retarget pid={top.Pid} {top.State} +{still.Count - 1}");
    }

    /// After the island or pill closes, once things are quiet: one trim for a burst of closes (a pill closes ~4 s
    /// after every done/input), not a full GC per event, and never while one of them is open again.
    void TrimLater()
    {
        if (trim == null)
        {
            trim = new System.Windows.Forms.Timer { Interval = 2000 };
            trim.Tick += (_, _) => { trim.Stop(); if (flyout == null && pill == null) TrayPlace.Trim(); };
        }
        trim.Stop();
        trim.Start();
    }

    public void Dispose()
    {
        engine.StateChanged -= OnStateChanged;
        GlowSettings.Shared.Changed -= OnSettingsChanged;
        pulse?.Dispose();
        coalesce?.Dispose();
        trim?.Dispose();
        flyout?.Close();
        pill?.Close();
        icon.Visible = false;
        icon.ContextMenuStrip?.Dispose();
        icon.Dispose();
        foreach (var (h, ic) in frames) { ic.Dispose(); DestroyIcon(h); }
    }
}
