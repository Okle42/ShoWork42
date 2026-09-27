using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using static ShoWork.Native;

namespace ShoWork;

/// System tray icon: a dot in the most urgent colour with the number of AI sessions in it (the Mac
/// menu bar's ●N), and a menu with 重新載入 / 結束. Redrawn only when the counts change.
sealed class Tray : IDisposable
{
    readonly NotifyIcon icon = new();
    IntPtr hicon;
    (int working, int done, int input) shown = (-1, -1, -1);

    public Tray(Action reload, Action quit)
    {
        // the menu (ToolStrip) is a big part of WinForms: build it the first time someone clicks the icon
        icon.MouseDown += (_, _) =>
        {
            if (icon.ContextMenuStrip != null) return;
            var menu = new ContextMenuStrip();
            menu.Items.Add("重新載入", null, (_, _) => reload());
            menu.Items.Add("結束", null, (_, _) => quit());
            icon.ContextMenuStrip = menu;
        };
        Update(0, 0, 0);
        icon.Visible = true;
    }

    public void Update(int working, int done, int input)
    {
        if (shown == (working, done, input)) return;
        shown = (working, done, input);
        var top = input > 0 ? WorkState.Input : done > 0 ? WorkState.Done : working > 0 ? WorkState.Working : WorkState.Idle;
        var old = hicon;
        hicon = Draw(working + done + input, top);
        icon.Icon = Icon.FromHandle(hicon);
        if (old != IntPtr.Zero) DestroyIcon(old);
        icon.Text = working + done + input == 0 ? "ShoWork42：沒有 AI 在工作" : $"ShoWork42：工作中 {working}・已完成 {done}・等你回答 {input}";
    }

    static IntPtr Draw(int count, WorkState top)
    {
        var size = SystemInformation.SmallIconSize.Width;            // 16 at 100 %, 24 at 150 %…
        using var bmp = new Bitmap(size, size);
        using var g = Graphics.FromImage(bmp);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        g.Clear(Color.Transparent);
        var c = top == WorkState.Idle ? Color.FromArgb(0x8E, 0x8E, 0x93) : GlowWindow.ColorOf(top);
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

    public void Dispose()
    {
        icon.Visible = false;
        icon.Dispose();
        if (hicon != IntPtr.Zero) DestroyIcon(hicon);
    }
}
