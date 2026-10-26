using System.Text;

namespace ShoWork;

// 戰情中心畫面的「量尺寸」部分（Mac 版 IslandView.swift 裡 IslandGeometry、BubbleFit、bubbleLine、KuboArt 的數學）。
// 不碰 WinForms：測試專案直接連這個檔，畫圖在 Board\View\。單位一律是邏輯像素（96 DPI＝1），畫的時候再乘 DPI 倍率。

/// 島的大小與每個座位的位置（座位排成 side×side 的等角格子）
public readonly struct IslandGeometry
{
    public const double K = 0.9;                   // 單張卡（160 寬）縮到島上的比例
    public const double Dx = 58, Dy = 29;
    public const double Top = 62;                  // 最後排角色＋泡泡要的高度
    public const double Depth = 14;
    public readonly int Side;
    public readonly double HalfW;
    public double HalfH => HalfW / 2;
    public (double X, double Y) Center => (HalfW + 6, Top + HalfH);
    public (double W, double H) Size => (HalfW * 2 + 12, Top + HalfW + Depth + 6);

    public IslandGeometry(int count)
    {
        Side = Math.Max(1, (int)Math.Ceiling(Math.Sqrt(Math.Max(count, 1))));
        HalfW = (Side - 1) * Dx + 80;
    }

    /// 第 n 個座位的地板中心；由後往前排，畫的順序就是 n 的順序
    public (double X, double Y) Spot(int n)
    {
        int r = n / Side, c = n % Side;
        var (cx, cy) = Center;
        return (cx + (c - r) * Dx, cy + (c + r - (Side - 1)) * Dy);
    }
}

/// 右側放得下幾個對話框：全部放得下就平分高度；放不下就顯示前幾個（最急的排前面）＋「還有 N 個」一格
public sealed class BubbleFit
{
    public const double Gap = 8, MinHeight = 36;   // 36＝精簡版（標題＋數字）放得下
    public readonly List<Islander> Visible;
    public readonly List<Islander> Hidden;
    public readonly int Slots;
    public readonly double Height;

    public BubbleFit(IReadOnlyList<Islander> people, double height)
    {
        double avail = height - 10;                                 // 上 4、下 6 留給外框線（線畫在邊上，貼齊會被裁掉）
        int cap = Math.Max(1, (int)((avail + Gap) / (MinHeight + Gap)));
        int n = Math.Max(people.Count, 1);
        if (n <= cap) { Slots = n; Visible = people.ToList(); Hidden = new(); }
        else
        {
            Slots = cap;
            int show = cap >= 2 ? cap - 1 : 1;                      // 留一格寫「還有 N 個」
            Visible = people.Take(show).ToList(); Hidden = people.Skip(show).ToList();
        }
        Height = Math.Max(MinHeight, (avail - Gap * (Slots - 1)) / Slots);
    }

    /// 框太矮（一座島好幾個人、視窗又小）⇒ 只留標題＋數字
    public static bool Compact(double h) => h < 56;
}

/// 一張島卡片裡各塊的位置（Mac IslandCard 的 frame 計算；單位邏輯像素，原點在卡片左上）
public readonly record struct IslandCardLayout(
    double IslandX, double IslandY, double IslandScale, IslandGeometry Geo,
    double BubbleX, double BubbleY, double BubbleW, double TextScale, BubbleFit Fit)
{
    public const double Pad = 10, HeaderH = 24;
    public const double DollShare = 0.42;          // 島（玩偶區）固定佔卡片寬的這個比例，剩下給對話框
    public const int MaxPeople = 16;

    public static IslandCardLayout Of(Island island, double width, double height)
    {
        var shown = island.People.Take(MaxPeople).ToList();
        var geo = new IslandGeometry(shown.Count);
        double innerW = width - Pad * 2, innerH = height - Pad * 2 - HeaderH - 4;
        double areaW = innerW * DollShare, areaH = innerH;
        var (gw, gh) = geo.Size;
        // 整座島（含角色）一起縮放到玩偶區大小
        double s = Math.Max(0.3, Math.Min(areaW / gw, areaH / gh));
        // 對話框平分右側整個高度；放不下就收成「還有 N 個」。卡片大，字也跟著大
        var fit = new BubbleFit(shown, areaH);
        double bubbleWForScale = innerW - areaW - 10 - 10;
        double k = Math.Min(1.6, Math.Max(1, Math.Min(fit.Height / 120, bubbleWForScale / 280)));
        double top = Pad + HeaderH + 4;
        // 島：玩偶區裡水平置中、靠上（對話框的尾巴才指得到角色）
        double ix = Pad + (areaW - gw * s) / 2;
        // 對話框欄：HStack 間距 10＋左 8（尾巴）、右 3、上 4
        double bx = Pad + areaW + 10 + 8;
        double bw = Math.Max(20, innerW - areaW - 10 - 8 - 3);
        return new IslandCardLayout(ix, top, s, geo, bx, top + 4, bw, k, fit);
    }
}

public static class BubbleText
{
    /// 一句話任務回報：要你決定的事 ＞ AI 自報摘要 ＞ AI 最後說的話 ＞ 欄位理由
    public static string Line(BoardCard c) =>
        c.Report?.Ask is { } ask ? $"要你決定：{ask}" : c.Report?.Summary ?? c.Detail ?? c.Reason;

    /// 📈 完成度、🎯 信心度（自報優先，沒有自報用審核的數字）
    public static int? Progress(BoardCard c) => c.Report?.Progress ?? c.Review?.Progress;
    public static int? Confidence(BoardCard c) => c.Report?.Confidence ?? c.Review?.Confidence;


    /// 流量表的「↻ 剩多久」：49 分、3:05、2天5時
    public static string Left(TimeSpan s)
    {
        int m = (int)(s.TotalSeconds / 60);
        if (m >= 24 * 60) return $"{m / 1440}天{m % 1440 / 60}時";
        return m >= 60 ? $"{m / 60}:{m % 60:00}" : $"{m} 分";
    }
}

/// ctx 超過門檻就該收尾（Mac ContextGuard）。門檻可調（Mac 10-15 Kang），存在 settings.json 的 general.ctxThreshold
public static partial class ContextGuard
{
    public const double DefaultThreshold = 85;
    public static readonly double[] Choices = { 60, 65, 70, 75, 80, 85, 90 };
    /// 讀進來的值不在 50～95 就當沒設（手改壞的設定檔不讓整排卡片變紅）
    public static double Clamp(double v) => v is >= 50 and <= 95 ? v : DefaultThreshold;
}

/// KuboArt 裡跟畫布無關的數學（動畫週期、雜湊）
public static class KuboMath
{
    /// 0…1…0 的三角波
    public static double Wave(double t, double period)
    {
        double x = t / period % 1;
        if (x < 0) x += 1;
        return x < 0.5 ? x * 2 : 2 - x * 2;
    }

    /// Swift 的 unicodeScalars.reduce(seed) { $0 &* 31 &+ $1.value }：跟 Mac 同一個專案拿到同一個島色
    public static uint Hash(string s, uint seed)
    {
        uint h = seed;
        foreach (var r in s.EnumerateRunes()) h = unchecked(h * 31 + (uint)r.Value);
        return h;
    }

    public const int PaletteCount = 7;
    public static int IslandColorIndex(string project) => (int)(Hash(project, 7) % PaletteCount);

    /// 每個角色的動作錯開一點（Mac 用 hashValue，每次啟動會變；這裡固定）
    public static double Phase(string id) => Hash(id, 11) % 1000 / 137.0;

    /// 影分身繞島：9 秒一圈，各自從不同角度出發；逆時針
    public static double GhostAngle(string id, double t) => t / 9 * 2 * Math.PI + Hash(id, 3) % 628 / 100.0;
    /// 在島的後半圈（被居民擋住，先畫）
    public static bool GhostBehind(string id, double t) => Math.Sin(GhostAngle(id, t)) < 0;

    public const double PuffSeconds = 0.6, FadeSeconds = 0.8, TypingPeriod = 0.5, Fps = 8;
}

/// 截圖驗收用的固定示範卡片（--board-demo）：六種狀態（含休息喝咖啡、從沒用過在睡覺）、隊長、耳機、眼鏡、影分身、擠滿 5 人的島都有
public static class BoardDemo
{
    static BoardCard Sleepy(BoardCard c) { c.Unused = true; c.LastActivity = null; return c; }

    public static List<BoardCard> Cards(DateTime now)
    {
        BoardCard C(string id, string project, BoardColumn col, string reason, string title, int? prog = null, int? conf = null,
                    double? ctx = null, string? summary = null, string? ask = null, string? visiting = null, bool captain = false) =>
            new()
            {
                Id = id, SessionId = id, Pid = 0, Column = col, Reason = reason, Project = project, Title = title,
                LastActivity = now.AddMinutes(-3), Kind = "interactive", Name = title, Visiting = visiting, Captain = captain,
                Report = prog == null && summary == null && ask == null ? null
                    : new SelfReport { Status = ReportStatus.Working, Progress = prog, Confidence = conf, Summary = summary, Ask = ask, At = now },
                Ctx = ctx is { } x ? new ContextUse { Percent = x } : null,
                Cwd = $@"C:\Users\demo\{project}",
            };
        return new List<BoardCard>
        {
            // 擠滿 5 人的島（右側放不下時收成「還有 N 個」）
            C("d1", "ShoWork42", BoardColumn.Active, "AI 正在工作", "Windows 戰情中心畫面", 60, 75, 42,
              "島和 Kubo 已經畫好，正在對 Mac 版的截圖逐部位比對；接下來量 CPU。", visiting: "ProjectA"),
            C("d2", "ShoWork42", BoardColumn.Review, "要你決定：要不要 push", "光暈朝內預設值", 90, 80, 71, ask: "要不要 push 到 windows-board？"),
            C("d3", "ShoWork42", BoardColumn.Review, "做完了，你還沒看", "設定頁深色模式", 100, 90, 18, "設定頁標題列跟著系統深色，六種光芒預覽都改好了。"),
            C("d4", "ShoWork42", BoardColumn.Stuck, "41 分鐘沒有新動靜", "安裝包簽章", 30, 40, 88, "等憑證檔，簽章工具找不到 signtool。"),
            C("d5", "ShoWork42", BoardColumn.Done, "閒置", "README 英文版"),
            // 隊長＋研究（眼鏡）
            C("d6", "ProjectA", BoardColumn.Active, "AI 正在工作", "派工與名冊整理", 45, 70, 33, "名冊 6 個 session，正在分派下一批任務。", captain: true),
            C("d7", "ProjectA", BoardColumn.Review, "做完了，你還沒看", "給排水法規研究", 100, 85, 9,
              "建築技術規則第 36、52、113 條整理完成，排水管徑表已更新。"),
            // 秘書（耳機）＋等你回答
            C("d8", "ProjectC", BoardColumn.Review, "等你回答", "LINE 自動回覆", 70, 65, 55, ask: "客人問週六能不能改時間，要怎麼回？"),
            C("d9", "ProjectC", BoardColumn.Done, "閒置", "平板連線檢查"),
            Sleepy(C("d10", "ProjectC", BoardColumn.Done, "閒置", "未命名")),                 // 開了沒用過：睡覺
        };
    }

    public static RateLimits Limits(DateTime now) => new()
    {
        FiveHour = new RateLimits.Window(27, now.AddMinutes(49)),
        SevenDay = new RateLimits.Window(72, now.AddDays(2).AddHours(5).AddMinutes(10)),
        SnapshotAt = now,
    };
}

/// 卡片格換成實際像素：每格的右緣、下緣都用 Floor，保證不超出捲動區（以前四捨五入會多 1px ⇒ 同時冒出直、橫捲軸，
/// 右欄被直捲軸蓋掉、最下排被橫捲軸切掉；審查 10-15 在 150% DPI、820×500、3 座島實拍到）。只往下捲，不往右捲。
public static class GridPixels
{
    public readonly record struct Cell(int X, int Y, int W, int H);

    /// width/height＝捲動區的實際像素；scrollBar＝直捲軸寬（實際像素）；s＝DPI 倍率；回傳每格位置、要不要捲、內容總高
    public static (List<Cell> Cells, bool Scroll, int ContentHeight) Place(int count, int width, int height, int scrollBar, double s, double gap = 12)
    {
        var cells = new List<Cell>();
        if (count <= 0 || width <= 0 || height <= 0) return (cells, false, 0);
        const double eps = 1e-6;                                          // 浮點誤差：剛好塞滿的 613.0000001 不算超出
        int Px(double logical) => (int)Math.Floor(logical * s + eps);
        var g = IslandGrid.Fit(count, width / s, height / s, gap);
        bool scroll = Px(g.Rows * g.Height + (g.Rows - 1) * gap) > height;
        int availW = width;
        if (scroll)
        {
            availW = Math.Max(1, width - scrollBar);                        // 直捲軸佔掉的寬度扣掉再排一次
            g = IslandGrid.Fit(count, availW / s, height / s, gap);
        }
        int bottom = 0;
        for (int i = 0; i < count; i++)
        {
            int r = i / g.Cols, c = i % g.Cols;
            int x0 = Px(c * (g.Width + gap)), x1 = Math.Min(availW, Px(c * (g.Width + gap) + g.Width));
            int y0 = Px(r * (g.Height + gap)), y1 = Px(r * (g.Height + gap) + g.Height);
            if (!scroll) y1 = Math.Min(height, y1);
            cells.Add(new Cell(x0, y0, Math.Max(0, x1 - x0), Math.Max(0, y1 - y0)));
            bottom = Math.Max(bottom, y1);
        }
        return (cells, scroll, scroll ? bottom : 0);
    }
}
