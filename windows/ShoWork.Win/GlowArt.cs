using System.Drawing;
using System.Runtime.InteropServices;

namespace ShoWork;

/// The pixels of one glow — used by the glow windows and by the settings preview, so the preview shows
/// exactly what the windows get. Port of the six Mac GlowView styles (Glow.swift).
///
/// Coordinates: the "overlay" is the target window grown by Pad on every side; the window outline sits at
/// (Pad, Pad, target). Pixels are premultiplied BGRA, drawn into caller-owned buffers for a few rectangles
/// ("parts") of the overlay: a moving style uses four strips around the window (the middle is covered by the
/// window anyway, and not keeping it saves most of the memory), a still one the whole overlay, the preview
/// the card's rectangle.
///
/// Inward (GlowDirection.Inward, the default since 09-29): the light starts at the window's visible edge and fades
/// towards its middle, drawn in a window ABOVE the target. Then Pad = 0 (the overlay is the window itself); a moving
/// style uses four strips just inside the edge, each `Depth` deep (Depth = the style's reach, see DepthFor), so a
/// frame never touches the middle; a still one is one window whose middle is fully transparent. Profile: a crisp
/// edge line 2 px wide at 96 DPI (×DPI) at alpha 0.55–0.85×brightness, then a soft Gaussian falloff whose peak is only 0.12–0.30×brightness, tapering to 0 at Depth — the first column
/// of terminal text sits under at most ~0.3 alpha of the colour and stays readable. Nothing outside the rounded
/// outline (8 px ×DPI corners; square when maximised) is drawn.
///
/// Cost model: for a moving style two maps are computed once per size — distance from the outline (1/4 px)
/// and angle around the centre. A frame is then a table lookup or two per pixel: the per-distance table is
/// rebuilt per frame (a few hundred entries) and the angle table is only rotated; sparks and blobs only
/// repaint where they were and are. A still glow is drawn once without maps; breathing is animated by the
/// window's constant alpha, not re-rendered.
sealed unsafe class GlowArt : IDisposable
{
    public readonly StateLook Look;
    public readonly bool Still;                  // animation effects off: a still glow for every style
    public readonly float S;                     // physical px per DIP (target's DPI / 96)
    public readonly int Pad;                     // outward: room around the window; inward: 0
    public readonly bool Inward;                 // light goes into the window (drawn above it)
    public readonly bool Square;                 // inward on a maximised window: no rounded corners
    public readonly int Depth;                   // inward: how far into the window the light reaches (0 outward)
    public readonly Size Target;
    public readonly Rectangle[] Parts;
    public Size Overlay => new(Target.Width + 2 * Pad, Target.Height + 2 * Pad);

    const int Q = 4;                             // distance map: quarter pixels
    readonly float off;                          // pixels up to `off` px inside the outline still get their own distance
    readonly float outside;                      // …and up to `outside` px outside it
    readonly int n;                              // entries in the per-distance tables
    readonly float corner;
    // native, freed by Dispose/Release: a slider drag rebuilds the art many times, and as managed arrays the
    // maps were large-object-heap garbage that kept the working set up long after
    ushort*[] dist;
    ushort*[]? ang;                              // only for the rotating styles
    int*[]? live;                                // rotating styles: pixels inside the ring mask, per part
    int[]? liveCount;
    uint* turn;                                  // rotating styles: pixel for (angle step, half-pixel distance)
    int nd;
    readonly Color c, light, deep;
    readonly uint[] pal, palLight;               // premultiplied colour for alpha 0…255
    readonly uint[] basePx;                      // still part of the style, per distance
    readonly int[] fade;                         // 0…256: fades out towards the pad and hides deep inside the window
    readonly uint[]? frame;                      // ripple: per-distance table rebuilt every frame

    /// inward: null = the setting (GlowSettings.General.Direction). square: the window has no rounded corners (maximised).
    public GlowArt(StateLook look, Size target, float s, Func<int, Rectangle[]>? parts = null, bool? still = null, bool? inward = null, bool square = false)
    {
        Look = look;
        Still = still ?? GlowSettings.ReduceMotion;
        S = s;
        Target = target;
        Inward = inward ?? GlowSettings.Shared.Inward;
        Square = square && Inward;                                           // outward keeps its exact W0–W4 look
        Pad = Inward ? 0 : PadFor(look, Style, s);
        Depth = Inward ? DepthFor(look, Style, s) : 0;
        corner = Square ? 0 : 8 * s;                                         // Windows 11 window corners
        // drawn once: one window (the pixels are not kept; inward its middle is fully transparent, and breathing is one
        // constant-alpha update per frame as outward); redrawn per frame: four strips around (outward) or just inside
        // (inward) the window's edge, so a frame never touches the middle
        Parts = parts?.Invoke(Pad) ?? (Fps == 0 ? new[] { new Rectangle(Point.Empty, Overlay) }
                                      : Inward ? InnerStrips(target, Depth, corner) : Strips(target, Pad, s));
        off = Inward ? Depth : 4 * s;
        outside = Inward ? 1.5f * s : Pad;                                   // inward: just the anti-aliased outline
        n = (int)((outside + off) * Q) + 2;
        c = look.Color;
        light = Mix(c, Color.White, 0.35f);
        deep = Mix(c, Color.Black, 0.35f);
        pal = Palette(c);
        palLight = Palette(Mix(c, Color.White, 0.3f));
        var style = Style;
        bool rotates = style is GlowStyle.Orbit or GlowStyle.Aurora;
        // maps only for styles drawn every frame; a still glow computes its distances once, on the fly
        dist = new ushort*[Fps > 0 ? Parts.Length : 0];
        if (rotates) ang = new ushort*[Parts.Length];
        for (int i = 0; i < dist.Length; i++) Map(i);

        float B = look.B, W = look.W;
        fade = new int[n];
        basePx = new uint[n];
        for (int i = 0; i < n && Inward; i++)
        {
            // e = how far inside the outline. Anti-aliased at the outline, tapering to 0 over the last 6 px of Depth —
            // smoothly over the inner 3/4 (drift) or half (sparkle) of it for the styles whose blobs/sparks move in,
            // or a big blob would end in a visible straight line
            float e = -D(i);
            float taper = style == GlowStyle.Drift ? .75f * Depth : style == GlowStyle.Sparkle ? .5f * Depth : 6 * s;
            float tt = Math.Clamp((Depth - e) / taper, 0, 1);
            float f = tt * tt * (3 - 2 * tt) * Math.Clamp(.5f + e, 0, 1);
            fade[i] = (int)(f * 256);
            var (lineA, softA, sigma) = InwardProfile(style);
            float lw = 2 * s;                                                // the crisp edge line: 2 px at 96 DPI
            float a = Screen(A(lineA) * Math.Clamp(lw + .5f - e, 0, 1), softA == 0 ? 0 : A(softA) * G(Math.Max(0, e - lw), sigma * W * s));
            basePx[i] = pal[(int)(a * f * 255)];
        }
        for (int i = 0; i < n && !Inward; i++)
        {
            float d = D(i);
            float f = Math.Clamp((Pad - d) / (6 * s), 0, 1) * Math.Clamp((d + 2.5f * s) / (2 * s), 0, 1);
            fade[i] = (int)(f * 256);
            float a = Edge(d), hw;
            switch (style)
            {
                case GlowStyle.Breathe: hw = 3 * W * s; a = Screen(a, Screen(A(.35f) * Cover(d, hw), A(.8f) * G(Math.Max(0, d - hw), 7 * W * s))); break;
                case GlowStyle.Ripple: hw = 3 * W * s; a = Screen(a, Screen(A(.4f) * Cover(d, hw), A(.9f) * G(Math.Max(0, d - hw), 6 * W * s))); break;
                case GlowStyle.Orbit: hw = 3 * W * s; a = Screen(a, Screen(A(.25f) * Cover(d, hw), A(.7f) * G(Math.Max(0, d - hw), 5 * W * s))); break;
                case GlowStyle.Sparkle: hw = 2.5f * W * s; a = Screen(a, Screen(A(.35f) * Cover(d, hw), A(.8f) * G(Math.Max(0, d - hw), 5 * W * s))); break;
            }
            basePx[i] = pal[(int)(a * f * 255)];
        }
        if (rotates)
        {
            var feather = new int[n];                                        // 0…256: soft ring mask
            float outer = (style == GlowStyle.Orbit ? 30 : 34) * W * s, inner = -2 * s;
            // inward: a narrower ring inside the edge (reaching 18W / 22W) and a dimmer arc — it passes over text
            float arc = .85f;
            if (Inward) { outer = (style == GlowStyle.Orbit ? 18 : 22) * W * s; inner = -1 * s; arc = style == GlowStyle.Orbit ? .55f : .5f; }
            for (int i = 0; i < n; i++)
            {
                float dd = Inward ? -D(i) : D(i);
                float t = (dd - inner) / (outer - inner);
                feather[i] = t < 0 || t > 1 ? 0 : (int)(256 * arc * MathF.Pow(1 - t, 1.4f) * (Inward ? fade[i] / 256f : 1));
            }
            var conic = style == GlowStyle.Orbit                               // 1024 steps around the window
                ? Conic(new[] { 0f, .62f, .8f, .9f, .93f, 1f },
                        new[] { Color.FromArgb(0, c), Color.FromArgb(0, c), Color.FromArgb(153, c), c, Color.FromArgb(230, 255, 255, 255), Color.FromArgb(0, 255, 255, 255) }, A(1))
                : Conic(new[] { 0f, .17f, .33f, .5f, .67f, .83f, 1f }, new[] { c, light, deep, c, light, deep, c }, A(.85f));
            // a rotating frame only shifts the angle: every (angle, distance) result is computed here once, so a
            // frame is one lookup per pixel (512 angles × half pixels: finer than the soft gradients need)
            nd = (n >> 1) + 1;
            turn = (uint*)NativeMemory.Alloc((nuint)(512 * nd), sizeof(uint));
            for (int ai = 0; ai < 512; ai++)
                for (int j = 0; j < nd; j++)
                {
                    int di = Math.Min(j * 2, n - 1), f = feather[di];
                    uint b = basePx[di], q = f == 0 ? 0 : conic[ai * 2];
                    if (q != 0) { q = Scale(q, f); b = q + Scale(b, 256 - (int)(q >> 24)); }
                    turn[ai * nd + j] = b;
                }
            // outside the ring mask a pixel never changes: after the first frame only these are redrawn
            live = new int*[Parts.Length];
            liveCount = new int[Parts.Length];
            for (int p = 0; p < Parts.Length; p++)
            {
                ushort* d = dist[p];
                int len = Len(p), k = 0;
                for (int i = 0; i < len; i++) if (feather[d[i]] > 0) k++;
                var l = live[p] = (int*)NativeMemory.Alloc((nuint)Math.Max(k, 1), sizeof(int));
                for (int i = 0, j = 0; i < len; i++) if (feather[d[i]] > 0) l[j++] = i;
                liveCount[p] = k;
            }
        }
        if (style == GlowStyle.Ripple) frame = new uint[n];
        if (style == GlowStyle.Drift) blob = Blob();
    }

    /// The style actually drawn: every style becomes a still breathing glow when animation effects are off.
    public GlowStyle Style => Still ? GlowStyle.Breathe : Look.Style;
    /// Frames per second the style needs (0 = drawn once). Capped at 30; the slow ones get less.
    public int Fps => Style switch { GlowStyle.Orbit or GlowStyle.Ripple => 30, GlowStyle.Sparkle => 24, GlowStyle.Drift or GlowStyle.Aurora => 15, _ => 0 };
    /// Breathing only changes the window's constant alpha.
    public bool Breathes => !Still && Look.Style == GlowStyle.Breathe;

    /// Room around the window for the style's glow to fade out completely (no hard edge) — and no more:
    /// a moving style pushes every pixel of the band to the screen each frame.
    public static int PadFor(StateLook look, GlowStyle style, float s) => (int)MathF.Ceiling(style switch
    {
        GlowStyle.Breathe => 8 + 26 * look.W,       // 3W stroke + 3σ of a 7W shadow
        GlowStyle.Orbit => 8 + 32 * look.W,         // the arc's ring mask reaches 30W
        GlowStyle.Aurora => 8 + 36 * look.W,        // 34W
        GlowStyle.Ripple => 16 + 40 * look.W,       // rings travel 40W
        _ => 10 + 44 * look.W,                      // sparks and blobs wander; they fade out at the edge
    } * s);

    /// Four non-overlapping strips around the window, each reaching `inset` into it for the rounded corners.
    public static Rectangle[] Strips(Size t, int pad, float s)
    {
        int inset = (int)MathF.Ceiling(12 * s);
        int w = t.Width + 2 * pad, h = t.Height + 2 * pad, band = pad + inset;
        if (2 * band >= Math.Min(w, h)) return new[] { new Rectangle(0, 0, w, h) };  // small window: one piece
        return new[]
        {
            new Rectangle(0, 0, w, band), new Rectangle(0, h - band, w, band),
            new Rectangle(0, band, band, h - 2 * band), new Rectangle(w - band, band, band, h - 2 * band),
        };
    }

    /// Inward: how deep the light reaches into the window (px) — the soft part has faded to nothing by then. Default
    /// (width 1×): 22–32 px at 96 DPI, a little less than the outward pad (34–56 px): this band lies over the text.
    public static int DepthFor(StateLook look, GlowStyle style, float s) => (int)MathF.Ceiling(style switch
    {
        GlowStyle.Breathe => 4 + 20 * look.W,       // 2 px line + 3σ of a 6W falloff
        GlowStyle.Orbit => 4 + 18 * look.W,         // the arc's ring mask reaches 18W
        GlowStyle.Aurora => 4 + 22 * look.W,        // 22W
        GlowStyle.Ripple => 8 + 24 * look.W,        // rings travel 24W inwards
        _ => 6 + 26 * look.W,                       // sparks and blobs drift in; they fade out at Depth
    } * s);

    /// Inward edge line alpha, soft falloff peak alpha and its σ (in W·DIP), per style (× brightness).
    static (float line, float soft, float sigma) InwardProfile(GlowStyle style) => style switch
    {
        GlowStyle.Breathe => (.85f, .30f, 6),
        GlowStyle.Ripple => (.70f, .16f, 4),
        GlowStyle.Orbit => (.60f, .14f, 4),
        GlowStyle.Aurora => (.55f, .12f, 4),
        GlowStyle.Sparkle => (.70f, .18f, 4),
        _ => (.70f, 0, 4),                          // 光霧飄動: the blobs are the soft part
    };

    /// Four non-overlapping strips just inside the window's edge, `depth` deep (at least the corner radius, so the
    /// rounded corners lie in the top and bottom strips): nothing covers the middle, no pixel is drawn twice.
    public static Rectangle[] InnerStrips(Size t, int depth, float corner)
    {
        int band = Math.Max(depth, (int)MathF.Ceiling(corner)) + 1;
        if (2 * band >= Math.Min(t.Width, t.Height)) return new[] { new Rectangle(Point.Empty, t) };   // small window: one piece
        return new[]
        {
            new Rectangle(0, 0, t.Width, band), new Rectangle(0, t.Height - band, t.Width, band),
            new Rectangle(0, band, band, t.Height - 2 * band), new Rectangle(t.Width - band, band, band, t.Height - 2 * band),
        };
    }

    /// Drop the per-pixel maps once a still glow has been drawn (Draw must not be called afterwards).
    public void Release()
    {
        foreach (var d in dist) NativeMemory.Free(d);
        if (ang != null) foreach (var a in ang) NativeMemory.Free(a);
        if (live != null) foreach (var l in live) NativeMemory.Free(l);
        NativeMemory.Free(turn);
        dist = new ushort*[0];
        ang = null;
        live = null;
        turn = null;
    }

    public void Dispose() { Release(); GC.SuppressFinalize(this); }
    ~GlowArt() => Release();

    int Len(int p) => Parts[p].Width * Parts[p].Height;

    // MARK: drawing

    /// 0…255 constant alpha for the breathing style at time t (seconds): 3.2 s per breath at speed 1.
    public byte AlphaAt(double t) =>
        Breathes ? (byte)(255 * (0.55 + 0.45 * (0.5 - 0.5 * Math.Cos(2 * Math.PI * t / (3.2 * Look.Period))))) : (byte)255;

    /// Draw the frame for time t into one buffer per part (Width×Height, top-down, no padding).
    /// bakeAlpha: multiply the breathing alpha into the pixels (the preview has no layered window to do it).
    public void Draw(double t, uint*[] bits, bool bakeAlpha = false)
    {
        switch (Style)
        {
            case GlowStyle.Orbit: Rotating(bits, t / (3.4 * Look.Period)); break;
            case GlowStyle.Aurora: Rotating(bits, t / (9 * Look.Period)); break;
            case GlowStyle.Ripple: Ripple(bits, t); break;
            case GlowStyle.Drift: Drift(bits, t); break;
            case GlowStyle.Sparkle: Sparkle(bits, t); break;
            default: Plain(bits, bakeAlpha ? AlphaAt(t) + 1 : 256); break;
        }
    }

    void Plain(uint*[] bits, int scale)
    {
        for (int p = 0; p < Parts.Length; p++)
        {
            var o = bits[p];
            if (p < dist.Length)
            {
                ushort* d = dist[p];
                fixed (uint* bp = basePx)
                {
                    int len = Len(p);
                    if (scale >= 256) for (int i = 0; i < len; i++) o[i] = bp[d[i]];
                    else for (int i = 0; i < len; i++) o[i] = Scale(bp[d[i]], scale);
                }
                continue;
            }
            // no map: distance per pixel, skipping the middle (deep inside the window everything is transparent)
            var r = Parts[p];
            float cx = Pad + Target.Width / 2f, cy = Pad + Target.Height / 2f, m = off + corner + 1;
            float skipX = Target.Width / 2f - m, skipY = Target.Height / 2f - m;
            int x0 = Math.Max(0, (int)(cx - skipX) - r.Left + 1), x1 = Math.Min(r.Width, (int)(cx + skipX) - r.Left - 1);
            for (int y = 0; y < r.Height; y++)
            {
                float py = r.Top + y + .5f - cy;
                uint* row = o + y * r.Width;
                bool middle = Math.Abs(py) < skipY && x1 > x0;
                for (int x = 0; x < r.Width; x++)
                {
                    if (middle && x == x0) { new Span<uint>(row + x0, x1 - x0).Clear(); x = x1 - 1; continue; }
                    uint v = basePx[DistAt(r.Left + x + .5f - cx, py)];
                    row[x] = scale >= 256 ? v : Scale(v, scale);
                }
            }
        }
    }

    // B. 流光繞行 / F. 極光旋轉 — a conic gradient turning clockwise, masked to a soft ring
    void Rotating(uint*[] bits, double turns)
    {
        int phase = (int)((turns - Math.Floor(turns)) * 512);
        if (!drawn) { Plain(bits, 256); drawn = true; }
        uint* tt = turn;
        for (int p = 0; p < Parts.Length; p++)
        {
            var o = bits[p];
            int* l = live![p];
            ushort* d = dist[p], a = ang![p];
            for (int k = 0, len = liveCount![p]; k < len; k++)
            {
                int i = l[k];
                o[i] = tt[(((a[i] >> 7) - phase) & 511) * nd + (d[i] >> 1)];
            }
        }
    }

    // C. 漣漪外擴 — three rings leave the frame and fade (3 s each, a third apart)
    void Ripple(uint*[] bits, double t)
    {
        double per = 3 * Look.Period;
        Span<float> r = stackalloc float[3], op = stackalloc float[3];
        for (int k = 0; k < 3; k++)
        {
            double u = t / per + k / 3.0;
            float e = 1 - MathF.Pow(1 - (float)(u - Math.Floor(u)), 2);           // ease out
            r[k] = e * (Inward ? 24 : 40) * Look.W * S;                           // inward: rings travel from the edge in
            op[k] = A(Inward ? .5f : .9f) * (1 - e);
        }
        var fr = frame!;
        for (int i = 0; i < n; i++)
        {
            float d = Inward ? -D(i) : D(i);
            float a = basePx[i] >> 24;
            a /= 255f;
            for (int k = 0; k < 3; k++)
            {
                float x = Math.Abs(d - r[k]);
                a = Screen(a, op[k] * Screen(Cover(x, S), .8f * G(Math.Max(0, x - S), 2 * S)) * fade[i] / 256f);
            }
            fr[i] = pal[(int)(Math.Min(1, a) * 255)];
        }
        for (int p = 0; p < Parts.Length; p++)
        {
            var o = bits[p];
            int len = Len(p);
            ushort* d = dist[p];
            fixed (uint* f = fr)
                for (int i = 0; i < len; i++) o[i] = f[d[i]];
        }
    }

    // D. 光霧飄動 — four soft blobs on the edges drift back and forth
    static readonly float[] DriftX = { .2f, 1, .7f, 0 }, DriftY = { 0, .35f, 1, .7f };
    static readonly float[] DriftDx = { 22, -18, 16, -20 }, DriftDy = { 12, -14, -10, 14 }, DriftT = { 7, 9, 8, 6 };
    static readonly float[] Logistic = Enumerable.Range(0, 256).Select(i => 1 / (1 + MathF.Exp((i / 16f - 8) * 1.8f))).ToArray();

    /// One soft ellipse (a blurred filled ellipse, like the Mac's shadow-only layer), alpha 0…255.
    /// All four blobs have the same shape, so it is drawn once and only moved per frame.
    readonly (byte[] a, int w, int h)? blob;

    (byte[], int, int) Blob()
    {
        float W = Look.W, bw = Math.Min(Target.Width, Target.Height) * .55f * Math.Min(W, 1.4f);
        float ax = bw / 2, by = bw * .3f, sigma = 13 * W * S, geo = MathF.Sqrt(ax * by);
        int w = (int)(2 * (ax + 3 * sigma)) + 1, h = (int)(2 * (by + 3 * sigma)) + 1;
        var a = new byte[w * h];
        for (int y = 0, i = 0; y < h; y++)
            for (int x = 0; x < w; x++, i++)
            {
                float dx = (x + .5f - w / 2f) / ax, dy = (y + .5f - h / 2f) / by;
                float sdf = (MathF.Sqrt(dx * dx + dy * dy) - 1) * geo / sigma;
                int li = (int)((sdf + 8) * 16);
                a[i] = (byte)(255 * (li < 0 ? 1 : li > 255 ? 0 : Logistic[li]));
            }
        return (a, w, h);
    }

    void Drift(uint*[] bits, double t)
    {
        var (sprite, bw, bh) = blob!.Value;
        int op = (int)(A(Inward ? .4f : .75f) * 256);                          // inward: over the text, fainter
        Clean(bits);
        for (int k = 0; k < 4; k++)
        {
            double u = 0.5 - 0.5 * Math.Cos(Math.PI * t / (DriftT[k] * Look.Period));
            float cx = Pad + DriftX[k] * Target.Width + (float)(DriftDx[k] * u) * S, cy = Pad + DriftY[k] * Target.Height + (float)(DriftDy[k] * u) * S;
            var box = new Rectangle((int)(cx - bw / 2f), (int)(cy - bh / 2f), bw, bh);
            dirty.Add(box);
            var pl = k % 2 == 0 ? pal : palLight;
            for (int p = 0; p < Parts.Length; p++)
            {
                var pr = Parts[p];
                var r = Rectangle.Intersect(pr, box);
                if (r.IsEmpty) continue;
                var d = dist[p]; var o = bits[p];
                for (int y = r.Top; y < r.Bottom; y++)
                {
                    int i = (y - pr.Top) * pr.Width + (r.Left - pr.Left), j = (y - box.Top) * bw + (r.Left - box.Left);
                    for (int x = r.Left; x < r.Right; x++, i++, j++)
                    {
                        int a = sprite[j] * fade[d[i]] * op >> 16;
                        if (a == 0) continue;
                        uint src = pl[Math.Min(a, 255)];
                        o[i] = src + Scale(o[i], 256 - (int)(src >> 24));
                    }
                }
            }
        }
    }

    // E. 微光粒子 — sparks leave the frame in every direction and fade (≈10 per second, 2.6 s each)
    struct Spark { public float X, Y, Vx, Vy, R; public double Born; }
    readonly List<Spark> sparks = new();
    readonly Random rng = new(42);
    double lastT = double.NaN, owed;
    readonly List<Rectangle> dirty = new();
    bool drawn;                                  // the buffers already hold this art's ring (they live as long as the art)

    /// Sparks and blobs move over a still ring: draw the ring once, then per frame only put it back where
    /// the last frame's sparks/blobs were.
    void Clean(uint*[] bits)
    {
        if (!drawn) { Plain(bits, 256); drawn = true; }
        else foreach (var box in dirty) Restore(bits, box);
        dirty.Clear();
    }

    void Restore(uint*[] bits, Rectangle box)
    {
        for (int p = 0; p < Parts.Length; p++)
        {
            var pr = Parts[p];
            var r = Rectangle.Intersect(pr, box);
            if (r.IsEmpty) continue;
            var d = dist[p]; var o = bits[p];
            for (int y = r.Top; y < r.Bottom; y++)
                for (int i = (y - pr.Top) * pr.Width + (r.Left - pr.Left), e = i + r.Width; i < e; i++) o[i] = basePx[d[i]];
        }
    }

    void Sparkle(uint*[] bits, double t)
    {
        double k = Look.Period, life = 2.6 * k, rate = 10 / k;
        if (double.IsNaN(lastT) || t < lastT || t - lastT > 1)                 // first frame or after a pause: already sparkling
        {
            sparks.Clear();
            for (int i = 0, m = (int)(rate * life); i < m; i++) sparks.Add(NewSpark(t - rng.NextDouble() * life));
            owed = 0;
        }
        else
        {
            owed += (t - lastT) * rate;
            for (; owed >= 1; owed--) sparks.Add(NewSpark(t - rng.NextDouble() * (t - lastT)));
        }
        lastT = t;
        sparks.RemoveAll(sp => t - sp.Born > life);
        Clean(bits);
        float sigma = 2 * S, fall = (float)(0.38 / k), top = A(Inward ? .8f : 1);
        foreach (var sp in sparks)
        {
            float age = (float)(t - sp.Born);
            float alpha = Math.Max(0, 1 - fall * age) * top;
            if (alpha <= 0) continue;
            float x0 = sp.X + sp.Vx * age, y0 = sp.Y + sp.Vy * age, rr = sp.R, reach = rr + 3 * sigma;
            var box = Rectangle.FromLTRB((int)(x0 - reach), (int)(y0 - reach), (int)(x0 + reach) + 1, (int)(y0 + reach) + 1);
            dirty.Add(box);
            Stamp(bits, box, (x, y, fd) =>
            {
                float dd = MathF.Sqrt((x - x0) * (x - x0) + (y - y0) * (y - y0));
                float ia = Screen(Math.Clamp(rr + .5f - dd, 0, 1), .7f * G(Math.Max(0, dd - rr), sigma)) * alpha * fd;
                return ia <= 0.004f ? 0 : palLight[(int)(Math.Min(1, ia) * 255)];
            });
        }
    }

    Spark NewSpark(double born)
    {
        float tw = Target.Width, th = Target.Height, u = (float)rng.NextDouble() * 2 * (tw + th), x, y;
        if (u < tw) { x = Pad + u; y = Pad; }
        else if (u < tw + th) { x = Pad + tw; y = Pad + u - tw; }
        else if (u < 2 * tw + th) { x = Pad + u - tw - th; y = Pad + th; }
        else { x = Pad; y = Pad + u - 2 * tw - th; }
        float v = (14 + ((float)rng.NextDouble() * 2 - 1) * 8) * Look.W * S, dir = (float)rng.NextDouble() * MathF.Tau;
        float vx = v * MathF.Cos(dir), vy = v * MathF.Sin(dir);
        if (Inward)
        {
            // head into the window: flip the part of the velocity that points out through the spark's edge
            if (u < tw) vy = Math.Abs(vy);
            else if (u < tw + th) vx = -Math.Abs(vx);
            else if (u < 2 * tw + th) vy = -Math.Abs(vy);
            else vx = Math.Abs(vx);
        }
        return new Spark { X = x, Y = y, Vx = vx, Vy = vy, R = 4 * S * (.45f + ((float)rng.NextDouble() * 2 - 1) * .25f), Born = born };
    }

    /// Composite `src(x, y, fade)` (pixel centre, overlay coords) over whatever the parts hold inside `box`.
    void Stamp(uint*[] bits, Rectangle box, Func<float, float, float, uint> src)
    {
        for (int p = 0; p < Parts.Length; p++)
        {
            var pr = Parts[p];
            var r = Rectangle.Intersect(pr, box);
            if (r.IsEmpty) continue;
            var d = dist[p]; var o = bits[p];
            for (int y = r.Top; y < r.Bottom; y++)
                for (int x = r.Left, i = (y - pr.Top) * pr.Width + (r.Left - pr.Left); x < r.Right; x++, i++)
                {
                    int fd = fade[d[i]];
                    if (fd == 0) continue;
                    uint s = src(x + .5f, y + .5f, fd / 256f);
                    if (s != 0) o[i] = s + Scale(o[i], 256 - (int)(s >> 24));
                }
        }
    }

    // MARK: maps and tables

    /// Signed distance from the rounded outline (outside > 0) and angle clockwise from 12 o'clock, per pixel.
    void Map(int p)
    {
        var r = Parts[p];
        var d = dist[p] = (ushort*)NativeMemory.Alloc((nuint)Len(p), sizeof(ushort));
        var a = ang == null ? null : ang[p] = (ushort*)NativeMemory.Alloc((nuint)Len(p), sizeof(ushort));
        float cx = Pad + Target.Width / 2f, cy = Pad + Target.Height / 2f;
        for (int y = 0, i = 0; y < r.Height; y++)
        {
            float py = r.Top + y + .5f - cy;
            for (int x = 0; x < r.Width; x++, i++)
            {
                float px = r.Left + x + .5f - cx;
                d[i] = DistAt(px, py);
                if (a != null)
                {
                    float th = MathF.Atan2(px, -py) / MathF.Tau;
                    a[i] = (ushort)((int)((th < 0 ? th + 1 : th) * 65536) & 0xFFFF);
                }
            }
        }
    }

    /// Table index for a point relative to the window centre: signed distance from the rounded outline.
    ushort DistAt(float px, float py)
    {
        float qx = Math.Abs(px) - (Target.Width / 2f - corner), qy = Math.Abs(py) - (Target.Height / 2f - corner);
        float ox = Math.Max(qx, 0), oy = Math.Max(qy, 0);
        float sd = MathF.Sqrt(ox * ox + oy * oy) + Math.Min(Math.Max(qx, qy), 0) - corner;
        return (ushort)Math.Clamp((int)((sd + off) * Q), 0, n - 1);
    }

    float D(int i) => i / (float)Q - off;
    float A(float a) => Math.Min(1, a * Look.B);                                        // alpha scaled by brightness
    float Edge(float d) => Screen(A(.95f) * Cover(d, 1.25f * S), A(.9f) * .6f * G(Math.Max(0, Math.Abs(d) - 1.25f * S), 2.5f * S));
    static float Cover(float x, float half) => Math.Clamp(half + .5f - Math.Abs(x), 0, 1);  // anti-aliased stroke
    static float G(float x, float sigma) => MathF.Exp(-.5f * x * x / (sigma * sigma));
    static float Screen(float a, float b) => a + b - a * b;

    static Color Mix(Color a, Color b, float t) =>
        Color.FromArgb((int)(a.R + (b.R - a.R) * t), (int)(a.G + (b.G - a.G) * t), (int)(a.B + (b.B - a.B) * t));

    static uint Premul(Color c, int a) => (uint)(a << 24 | c.R * a / 255 << 16 | c.G * a / 255 << 8 | c.B * a / 255);
    static uint[] Palette(Color c) { var p = new uint[256]; for (int a = 0; a < 256; a++) p[a] = Premul(c, a); return p; }

    /// Premultiplied pixel × f/256, two channels per multiply.
    static uint Scale(uint px, int f) => ((px & 0x00FF00FF) * (uint)f >> 8 & 0x00FF00FF) | ((px >> 8 & 0x00FF00FF) * (uint)f & 0xFF00FF00);

    /// 1024 steps of a conic gradient, colours interpolated between stops, alpha × `alpha`.
    static uint[] Conic(float[] stops, Color[] colors, float alpha)
    {
        var lut = new uint[1024];
        for (int i = 0, k = 0; i < 1024; i++)
        {
            float u = i / 1024f;
            while (k < stops.Length - 2 && u > stops[k + 1]) k++;
            float t = Math.Clamp((u - stops[k]) / (stops[k + 1] - stops[k]), 0, 1);
            Color a = colors[k], b = colors[k + 1];
            float al = (a.A + (b.A - a.A) * t) / 255f * alpha;
            var mixed = Color.FromArgb((int)(a.R + (b.R - a.R) * t), (int)(a.G + (b.G - a.G) * t), (int)(a.B + (b.B - a.B) * t));
            lut[i] = Premul(mixed, (int)(al * 255));
        }
        return lut;
    }
}
