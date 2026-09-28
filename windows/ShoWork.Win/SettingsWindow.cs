using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace ShoWork;

/// Settings window, same structure as the Mac SettingsPanel: pages 「光暈」 and 「一般」, everything applies the
/// moment you change it. Created on demand and disposed on close (the agent stays small while nobody looks).
/// Follows the Windows app theme (dark/light) when it opens.
sealed class SettingsWindow : Form
{
    static SettingsWindow? instance;

    /// Open the settings window, or bring the open one to the front. UI thread only.
    public static void ShowSingleton()
    {
        if (instance == null || instance.IsDisposed) { instance = new SettingsWindow(); instance.Show(); }
        else { instance.autostartOn = Installer.Autostart() != null; instance.FromSettings(); }   // --uninstall may have run meanwhile
        if (instance.WindowState == FormWindowState.Minimized) instance.WindowState = FormWindowState.Normal;
        instance.Activate();
    }

    static readonly WorkState[] States = { WorkState.Working, WorkState.Done, WorkState.Input };
    static string StateName(WorkState s) => s switch { WorkState.Working => "工作中", WorkState.Done => "已完成", _ => "等你回答" };
    static string Hint(WorkState s) => s switch
    {
        WorkState.Working => "AI 正在處理時，視窗外圍的光。",
        WorkState.Done => "AI 做完了、等你來看時的光。在那個視窗裡按鍵或點擊就會消失。",
        _ => "AI 在等你回覆或允許權限時的光。要等 AI 繼續才會消失。",
    };

    readonly Theme th = Theme.Current();
    readonly GlowSettings settings = GlowSettings.Shared;
    WorkState editing = WorkState.Working;
    bool syncing;                                          // updating controls from settings: don't write back
    bool autostartOn = Installer.Autostart() != null;      // the registry, read on open and after a change (not per slider tick)

    readonly RadioButton tabGlow, tabGeneral;
    readonly Panel glowPage, generalPage;
    readonly GlowPreview[] previews = new GlowPreview[3];
    readonly Toggle[] switches = new Toggle[3];
    readonly Label[] names = new Label[3];
    readonly Label hint, section, colorHex;
    readonly Button colorButton, reset;
    readonly ComboBox style;
    readonly (TrackBar bar, Label value)[] sliders = new (TrackBar, Label)[3];
    readonly CheckBox autoArrange, autostart;
    readonly Font bold;

    SettingsWindow()
    {
        SuspendLayout();
        AutoScaleDimensions = new SizeF(96F, 96F);
        AutoScaleMode = AutoScaleMode.Dpi;
        Text = "ShoWork42 設定";
        Font = new Font("Microsoft JhengHei UI", 9.75F);
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(680, 620);
        BackColor = th.Back;
        ForeColor = th.Text;
        KeyPreview = true;
        bold = new Font(Font, FontStyle.Bold);

        // page switcher: two flat toggle buttons, like the Mac toolbar tabs
        tabGlow = Tab("光暈", 20);
        tabGeneral = Tab("一般", 110);
        Controls.Add(new Panel { Bounds = new Rectangle(0, 52, 680, 1), BackColor = th.Border });

        glowPage = new Panel { Bounds = new Rectangle(0, 53, 680, 567), BackColor = th.Back };
        generalPage = new Panel { Bounds = glowPage.Bounds, BackColor = th.Back, Visible = false };
        Controls.Add(glowPage);
        Controls.Add(generalPage);

        // 光暈: three live preview cards side by side (click one to tune it below)
        for (int i = 0; i < 3; i++)
        {
            var s = States[i];
            int x = 20 + i * 216;
            var p = previews[i] = new GlowPreview(s, th) { Bounds = new Rectangle(x, 18, 208, 124), Cursor = Cursors.Hand, AccessibleName = $"{StateName(s)}光芒預覽", Text = $"{StateName(s)}光芒預覽" };
            p.Click += (_, _) => Choose(s);
            glowPage.Controls.Add(p);
            var n = names[i] = new Label { Text = StateName(s), Bounds = new Rectangle(x, 150, 140, 24), TextAlign = ContentAlignment.MiddleLeft, Cursor = Cursors.Hand };
            n.Click += (_, _) => Choose(s);
            glowPage.Controls.Add(n);
            var t = switches[i] = new Toggle(th) { Bounds = new Rectangle(x + 208 - 44, 151, 44, 22), AccessibleName = $"顯示{StateName(s)}的光" };
            t.CheckedChanged += (_, _) => { if (!syncing) settings.Set(s, settings.Look(s) with { Enabled = t.Checked }); };
            glowPage.Controls.Add(t);
        }
        hint = new Label { Bounds = new Rectangle(20, 180, 640, 22), ForeColor = th.Secondary };
        glowPage.Controls.Add(hint);

        var box = new Panel { Bounds = new Rectangle(20, 212, 640, 300), BackColor = th.Card };
        box.Paint += (_, e) => { using var pen = new Pen(th.Border); e.Graphics.DrawRectangle(pen, 0, 0, box.Width - 1, box.Height - 1); };
        glowPage.Controls.Add(box);
        section = new Label { Bounds = new Rectangle(16, 12, 400, 24), Font = bold, BackColor = th.Card };
        box.Controls.Add(section);

        int row = 48;
        box.Controls.Add(RowLabel("顏色", row));
        colorButton = new Button { Bounds = new Rectangle(120, row, 44, 26), FlatStyle = FlatStyle.Flat, AccessibleName = "顏色" };
        colorButton.FlatAppearance.BorderColor = th.Border;
        colorButton.Click += (_, _) => PickColor();
        box.Controls.Add(colorButton);
        colorHex = new Label { Bounds = new Rectangle(172, row, 120, 26), TextAlign = ContentAlignment.MiddleLeft, ForeColor = th.Secondary, BackColor = th.Card };
        box.Controls.Add(colorHex);

        row += 44;
        box.Controls.Add(RowLabel("款式", row));
        style = new ComboBox { Bounds = new Rectangle(120, row, 200, 26), DropDownStyle = ComboBoxStyle.DropDownList, FlatStyle = FlatStyle.Flat,
                               BackColor = th.Input, ForeColor = th.Text, AccessibleName = "款式" };
        style.Items.AddRange(Enum.GetValues<GlowStyle>().Select(GlowSettings.Title).ToArray<object>());
        style.SelectedIndexChanged += (_, _) => { if (!syncing && style.SelectedIndex >= 0) Edit(l => l with { Style = (GlowStyle)style.SelectedIndex }); };
        box.Controls.Add(style);

        var specs = new (string title, string low, string high, int min, int max, Func<StateLook, double> get, Func<StateLook, double, StateLook> set)[]
        {
            ("亮度", "淡", "亮", 3, 16, l => l.Brightness, (l, v) => l with { Brightness = v }),
            ("寬度", "窄", "寬", 5, 20, l => l.Width, (l, v) => l with { Width = v }),
            ("速度", "慢", "快", 4, 25, l => l.Speed, (l, v) => l with { Speed = v }),
        };
        for (int i = 0; i < 3; i++)
        {
            var sp = specs[i];
            row += 44;
            box.Controls.Add(RowLabel(sp.title, row));
            box.Controls.Add(new Label { Text = sp.low, Bounds = new Rectangle(120, row, 28, 30), TextAlign = ContentAlignment.MiddleRight, ForeColor = th.Secondary, BackColor = th.Card });
            // AutoSize off BEFORE the bounds, or the bar takes its default 45 px height and covers the next row
            var bar = new TrackBar { AutoSize = false, Bounds = new Rectangle(150, row, 300, 30), Minimum = sp.min, Maximum = sp.max, TickStyle = TickStyle.None,
                                     BackColor = th.Card, AccessibleName = sp.title, SmallChange = 1, LargeChange = 2 };
            var value = new Label { Bounds = new Rectangle(490, row, 60, 30), TextAlign = ContentAlignment.MiddleRight, ForeColor = th.Secondary, BackColor = th.Card };
            bar.ValueChanged += (_, _) =>
            {
                value.Text = $"{bar.Value / 10.0:0.0}×";
                if (!syncing) Edit(l => sp.set(l, bar.Value / 10.0));
            };
            box.Controls.Add(bar);
            box.Controls.Add(new Label { Text = sp.high, Bounds = new Rectangle(452, row, 28, 30), TextAlign = ContentAlignment.MiddleLeft, ForeColor = th.Secondary, BackColor = th.Card });
            box.Controls.Add(value);
            sliders[i] = (bar, value);
        }
        reset = new Button { Bounds = new Rectangle(420, 524, 240, 30), FlatStyle = FlatStyle.Flat, BackColor = th.Card, ForeColor = th.Text };
        reset.FlatAppearance.BorderColor = th.Border;
        reset.Click += (_, _) => settings.Reset(editing);
        glowPage.Controls.Add(reset);

        // 一般
        autoArrange = Check("視窗數量變動時自動排版", 24);
        autoArrange.CheckedChanged += (_, _) => { if (!syncing) settings.SetGeneral(settings.General with { AutoArrange = autoArrange.Checked }); };
        generalPage.Controls.Add(Note("開或關一個終端機視窗時，自動把所有終端機視窗重新排好。", 52));
        autostart = Check("開機時啟動", 96);
        autostart.CheckedChanged += (_, _) => { if (!syncing) SetAutostart(autostart.Checked); };
        generalPage.Controls.Add(Note("登入 Windows 後自動在背景執行 ShoWork42（系統匣會出現圖示）。", 124));
        generalPage.Controls.Add(new Panel { Bounds = new Rectangle(20, 170, 640, 1), BackColor = th.Border });
        generalPage.Controls.Add(Note("設定、狀態與紀錄檔（SHOWORK_DEBUG=1 時）都放在這個資料夾。", 186));
        var open = new Button { Text = "開啟資料夾", Bounds = new Rectangle(20, 216, 140, 30), FlatStyle = FlatStyle.Flat, BackColor = th.Card, ForeColor = th.Text };
        open.FlatAppearance.BorderColor = th.Border;
        open.Click += (_, _) =>
        {
            Directory.CreateDirectory(Wire.SupportDir);
            Process.Start(new ProcessStartInfo("explorer.exe") { ArgumentList = { Wire.SupportDir }, UseShellExecute = false });
        };
        generalPage.Controls.Add(open);

        ResumeLayout(false);
        settings.Changed += FromSettings;
        FromSettings();
        Choose(WorkState.Working);
        tabGlow.Checked = true;
    }

    // MARK: controls ↔ settings

    void Choose(WorkState s)
    {
        editing = s;
        FromSettings();
    }

    void Edit(Func<StateLook, StateLook> change) => settings.Set(editing, change(settings.Look(editing)));

    /// Settings are the truth: every control is refreshed from them after any change (ours or the reset button).
    void FromSettings()
    {
        syncing = true;
        try
        {
            for (int i = 0; i < 3; i++)
            {
                var look = settings.Look(States[i]);
                switches[i].Checked = look.Enabled;
                previews[i].Show(look, States[i] == editing);
                names[i].Font = States[i] == editing ? bold : Font;
            }
            var l = settings.Look(editing);
            hint.Text = Hint(editing);
            section.Text = $"{StateName(editing)}　外觀";
            colorButton.BackColor = l.Color;
            colorButton.FlatAppearance.MouseOverBackColor = l.Color;
            colorHex.Text = l.Hex;
            style.SelectedIndex = (int)l.Style;
            var values = new[] { l.Brightness, l.Width, l.Speed };
            for (int i = 0; i < 3; i++)
            {
                var (bar, value) = sliders[i];
                bar.Value = Math.Clamp((int)Math.Round(values[i] * 10), bar.Minimum, bar.Maximum);
                value.Text = $"{bar.Value / 10.0:0.0}×";
            }
            foreach (var c in new Control[] { colorButton, style, sliders[0].bar, sliders[1].bar, sliders[2].bar }) c.Enabled = l.Enabled;
            reset.Text = $"回復「{StateName(editing)}」的預設值";
            autoArrange.Checked = settings.General.AutoArrange;
            autostart.Checked = autostartOn;                            // the registry is the truth
        }
        finally { syncing = false; }
    }

    void PickColor()
    {
        using var dlg = new ColorDialog { Color = settings.Look(editing).Color, FullOpen = true, AnyColor = true,
                                          CustomColors = GlowSettings.Defaults.Values.Select(d => ColorTranslator.ToWin32(d.Color)).ToArray() };
        if (dlg.ShowDialog(this) == DialogResult.OK) Edit(l => l with { Hex = StateLook.ToHex(dlg.Color) });
    }

    /// HKCU Run points at the installed copy when there is one, else at this exe.
    void SetAutostart(bool on)
    {
        var installed = Path.Combine(Installer.InstallDir, "ShoWorkAgent.exe");
        try { Installer.SetAutostart(on, File.Exists(installed) ? installed : Environment.ProcessPath!); }
        catch (Exception e) { Log.Note($"AUTOSTART {e.Message}"); }
        autostartOn = Installer.Autostart() != null;
        settings.SetGeneral(settings.General with { Autostart = autostartOn });
        FromSettings();            // always: when the write failed SetGeneral changes nothing, fires nothing, and the box would lie
    }

    // MARK: building blocks

    RadioButton Tab(string text, int x)
    {
        var r = new RadioButton
        {
            Text = text, Appearance = Appearance.Button, FlatStyle = FlatStyle.Flat, TextAlign = ContentAlignment.MiddleCenter,
            Bounds = new Rectangle(x, 12, 82, 30), BackColor = th.Back, ForeColor = th.Text, Cursor = Cursors.Hand,
        };
        r.FlatAppearance.BorderSize = 0;
        r.FlatAppearance.CheckedBackColor = th.Selected;
        r.FlatAppearance.MouseOverBackColor = th.Hover;
        r.CheckedChanged += (_, _) =>
        {
            if (!r.Checked) return;
            glowPage.Visible = r == tabGlow;
            generalPage.Visible = r == tabGeneral;
            foreach (var p in previews) p.Animate(glowPage.Visible);
        };
        Controls.Add(r);
        return r;
    }

    Label RowLabel(string text, int y) => new() { Text = text, Bounds = new Rectangle(16, y, 90, 26), TextAlign = ContentAlignment.MiddleLeft, BackColor = th.Card };

    CheckBox Check(string text, int y)
    {
        var c = new CheckBox { Text = text, Bounds = new Rectangle(20, y, 500, 26), ForeColor = th.Text, BackColor = th.Back };
        generalPage.Controls.Add(c);
        return c;
    }

    Label Note(string text, int y) => new() { Text = text, Bounds = new Rectangle(42, y, 620, 22), ForeColor = th.Secondary };

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        int dark = th.Dark ? 1 : 0;
        DwmSetWindowAttribute(Handle, 20 /*DWMWA_USE_IMMERSIVE_DARK_MODE*/, ref dark, sizeof(int));   // dark title bar
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        if (e.KeyCode == Keys.Escape) Close();
        base.OnKeyDown(e);
    }

    /// Minimised: the previews stop drawing.
    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        if (glowPage == null) return;                      // still being built
        foreach (var p in previews) p.Animate(WindowState != FormWindowState.Minimized && glowPage.Visible);
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        settings.Changed -= FromSettings;
        settings.Flush();
        if (instance == this) instance = null;
        base.OnFormClosed(e);
        bold.Dispose();
        // hand the window's memory back while nobody looks: collect it, then trim the working set — the pages the
        // window touched (WinForms controls, fonts, GDI+) stay out until it opens again; whatever the agent itself
        // still uses comes back as cheap soft faults. What Windows does to a minimised app.
        SynchronizationContext.Current?.Post(_ =>
        {
            GC.Collect();
            GC.WaitForPendingFinalizers();
            using var me = Process.GetCurrentProcess();
            SetProcessWorkingSetSize(me.Handle, -1, -1);
        }, null);
    }

    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    [DllImport("kernel32.dll")] static extern bool SetProcessWorkingSetSize(IntPtr process, nint min, nint max);

    // MARK: theme

    sealed record Theme(bool Dark, Color Back, Color Card, Color Input, Color Text, Color Secondary, Color Border, Color Selected, Color Hover, Color Accent)
    {
        /// HKCU …\Themes\Personalize AppsUseLightTheme = 0 ⇒ dark.
        public static Theme Current()
        {
            bool dark = false;
            try { dark = Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1) is 0; } catch { }
            return dark
                ? new(true, C(0x202020), C(0x2B2B2B), C(0x383838), C(0xFFFFFF), C(0xA8A8A8), C(0x3D3D3D), C(0x3A3A3A), C(0x333333), C(0x4CC2FF))
                : new(false, C(0xF3F3F3), C(0xFFFFFF), C(0xFFFFFF), C(0x1B1B1B), C(0x5F5F5F), C(0xE0E0E0), C(0xE4E4E4), C(0xEAEAEA), C(0x0067C0));
        }
        static Color C(int rgb) => Color.FromArgb((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF);
    }

    /// An on/off switch (WinForms has none): a pill with a knob.
    sealed class Toggle : CheckBox
    {
        readonly Theme th;
        public Toggle(Theme th)
        {
            this.th = th;
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
            Cursor = Cursors.Hand;
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.Clear(Parent?.BackColor ?? th.Back);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            float h = Height - 4, w = Math.Min(Width - 2, h * 2);
            var r = new RectangleF(Width - w - 1, 2, w, h);
            using (var path = Pill(r))
            {
                using var fill = new SolidBrush(Checked ? th.Accent : th.Dark ? Color.FromArgb(0x55, 0x55, 0x55) : Color.FromArgb(0xC8, 0xC8, 0xC8));
                g.FillPath(fill, path);
            }
            float k = h - 6;
            var knob = new RectangleF(Checked ? r.Right - k - 3 : r.Left + 3, r.Top + 3, k, k);
            using var kb = new SolidBrush(Color.White);
            g.FillEllipse(kb, knob);
            if (Focused) ControlPaint.DrawFocusRectangle(g, Rectangle.Round(r));
        }
        static GraphicsPath Pill(RectangleF r)
        {
            var p = new GraphicsPath();
            p.AddArc(r.Left, r.Top, r.Height, r.Height, 90, 180);
            p.AddArc(r.Right - r.Height, r.Top, r.Height, r.Height, 270, 180);
            p.CloseFigure();
            return p;
        }
    }

    /// A mock terminal window with the real glow pixels (GlowArt) around it — what you see is what the windows get.
    sealed class GlowPreview : Control
    {
        readonly WorkState state;
        readonly Theme th;
        readonly System.Windows.Forms.Timer timer = new();
        StateLook? look;
        GlowArt? art;
        Bitmap? bmp;
        bool selected, animate = true;

        public GlowPreview(WorkState state, Theme th)
        {
            this.state = state;
            this.th = th;
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.Selectable, true);
            TabStop = true;
            timer.Tick += (_, _) => { Render(); Invalidate(); };
        }

        // a card acts as a button: Tab to it, Space/Enter selects it (its Text is the name screen readers read)
        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.KeyCode is Keys.Space or Keys.Enter) { OnClick(EventArgs.Empty); e.Handled = true; }
            base.OnKeyDown(e);
        }
        protected override void OnGotFocus(EventArgs e) { base.OnGotFocus(e); Invalidate(); }
        protected override void OnLostFocus(EventArgs e) { base.OnLostFocus(e); Invalidate(); }

        public void Show(StateLook l, bool isSelected)
        {
            if (l == look && isSelected == selected) return;
            if (l != look) { look = l; Forget(); }
            selected = isSelected;
            Render();
            Invalidate();
        }

        public void Animate(bool on) { animate = on; Render(); }

        Rectangle Mock
        {
            get
            {
                int ww = Math.Min(Width / 2, (int)(220 * DeviceDpi / 96f)), wh = (int)(Height * .45f);
                return new Rectangle((Width - ww) / 2, (Height - wh) / 2, ww, wh);
            }
        }

        unsafe void Render()
        {
            if (look == null || Width < 8 || Height < 8) return;
            var m = Mock;
            if (art == null || art.Target != m.Size || bmp == null || bmp.Size != Size)
            {
                art?.Dispose();
                art = new GlowArt(look, m.Size, DeviceDpi / 96f, pad => new[] { new Rectangle(pad - m.X, pad - m.Y, Width, Height) });
                bmp?.Dispose();
                bmp = new Bitmap(Width, Height, PixelFormat.Format32bppPArgb);
            }
            var data = bmp.LockBits(new Rectangle(Point.Empty, bmp.Size), ImageLockMode.WriteOnly, PixelFormat.Format32bppPArgb);
            try { art.Draw(Environment.TickCount64 / 1000.0, new[] { (uint*)data.Scan0 }, bakeAlpha: true); }
            finally { bmp.UnlockBits(data); }
            int fps = art.Fps > 0 ? art.Fps : art.Breathes ? 20 : 0;
            if (fps > 0 && animate && Visible) { timer.Interval = 1000 / fps; timer.Start(); } else timer.Stop();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(th.Back);
            using (var clip = Rounded(new RectangleF(0, 0, Width - 1, Height - 1), 8 * DeviceDpi / 96f))
            {
                using var bg = new SolidBrush(Color.FromArgb(13, 15, 23));
                g.FillPath(bg, clip);
                g.SetClip(clip);
                if (bmp != null)
                {
                    if (look?.Enabled == false)
                    {
                        using var ia = new ImageAttributes();
                        ia.SetColorMatrix(new ColorMatrix { Matrix33 = .3f });
                        g.DrawImage(bmp, new Rectangle(Point.Empty, bmp.Size), 0, 0, bmp.Width, bmp.Height, GraphicsUnit.Pixel, ia);
                    }
                    else g.DrawImageUnscaled(bmp, 0, 0);
                }
                var m = Mock;
                using (var win = Rounded(m, 8 * DeviceDpi / 96f))
                using (var wb = new SolidBrush(Color.FromArgb(31, 36, 46)))
                    g.FillPath(wb, win);
                using (var tb = new SolidBrush(Color.FromArgb(90, 255, 255, 255)))       // a hint of a prompt line
                    g.FillRectangle(tb, m.X + m.Width * .12f, m.Y + m.Height * .3f, m.Width * .45f, Math.Max(2, m.Height * .07f));
                g.ResetClip();
                if (Focused) ControlPaint.DrawFocusRectangle(g, new Rectangle(4, 4, Width - 8, Height - 8));
                if (selected)
                {
                    using var pen = new Pen(th.Accent, 2 * DeviceDpi / 96f);
                    using var sel = Rounded(new RectangleF(1, 1, Width - 3, Height - 3), 8 * DeviceDpi / 96f);
                    g.DrawPath(pen, sel);
                }
            }
        }

        static GraphicsPath Rounded(RectangleF r, float rad)
        {
            var p = new GraphicsPath();
            float d = rad * 2;
            p.AddArc(r.Left, r.Top, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Top, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.Left, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        protected override void OnVisibleChanged(EventArgs e) { base.OnVisibleChanged(e); Render(); }
        protected override void OnResize(EventArgs e) { base.OnResize(e); Forget(); Render(); }
        void Forget() { art?.Dispose(); art = null; }

        protected override void Dispose(bool disposing)
        {
            if (disposing) { timer.Dispose(); bmp?.Dispose(); art?.Dispose(); }
            base.Dispose(disposing);
        }
    }
}
