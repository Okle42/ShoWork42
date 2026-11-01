namespace ShoWork;

// Mac 版 Sources/ShoWorkCore/Wander.swift 的逐行轉寫（11-02 P8）。
// 角色閒晃（10-20，規範 §4）：決定每個角色現在待哪（自己的桌、同層茶水角、拜訪別層、頂樓花園）、要不要出發、走哪條路。
//   純邏輯、可重現：隨機數用「session id＋15 秒時段」當種子（同一個時段重算幾次結果都一樣）。
//   不新增 timer：只在看板既有的刷新時呼叫。每次最多出發 1 人、全棟同時最多 3 人在路上。
//   狀態優先：等你回答一定在桌前（直接瞬移回來，不播）；工作中／卡住／還沒交代過事的回座位；休息的上頂樓、一樓咖啡館或地下室 B1 看神經網路（下雨不上頂樓）；只有「做完了你還沒看」的會隨機閒晃。
// 路線是預先算好的折線節點（模組本地座標＋樓層 id），畫面照節點時間插值，不做尋路、不做碰撞。

/// 角色現在（或這趟走完之後）待的地方（Swift enum 有附帶值 ⇒ JSON 是 "desk" 或 {"$case":"cafe","$value":{"slot":0}}）
public sealed record WanderSpot(string Case, int Slot = 0, string? Floor = null, string? Host = null) : IMacEnum
{
    public static readonly WanderSpot desk = new("desk");                                  // 自己樓層的座位
    public static WanderSpot lounge(int slot) => new("lounge", slot);                      // 自己樓層前帶（F1／F3）
    public static WanderSpot visit(string floor, string host) => new("visit", Floor: floor, Host: host);   // 拜訪別層：floor＝樓層 id，host＝對方 session id
    public static WanderSpot roof(int slot) => new("roof", slot);                          // 頂樓花園站位
    public static WanderSpot cafe(int slot) => new("cafe", slot);                          // 一樓後段咖啡館站位（10-22 Kang：下雨不該在頂樓喝咖啡）
    public static WanderSpot b1(int slot) => new("b1", slot);                              // 地下室 B1 機房：圍著投影台看神經網路

    public bool isDesk => Case == "desk";
    public bool isRoof => Case == "roof";
    public bool isCafe => Case == "cafe";
    public bool isB1 => Case == "b1";
    /// 室內休息點（咖啡館、B1）：下雨也待得住
    public bool isIndoorRest => isCafe || isB1;

    object? IMacEnum.Value => Case switch
    {
        "desk" => null,
        "visit" => new SortedDictionary<string, object?> { ["floor"] = Floor, ["host"] = Host },
        _ => new SortedDictionary<string, object?> { ["slot"] = Slot },
    };
    string IMacEnum.Case => Case;
}

/// 路線上的一個點：抵達這個點的方式＋從出發算起第幾秒抵達
public sealed record WanderNode
{
    public enum MoveKind { start, walk, elevator, slide, teleport, wait }
    public string Floor { get; set; } = "";       // TowerFloor.id（模組本地座標；搬家時跟著模組走）
    public double X { get; set; }
    public double Z { get; set; }
    public MoveKind Move { get; set; }
    public double T { get; set; }
    public int? Car { get; set; }                 // 搭哪一部電梯（move == .elevator 才有；10-22 兩部電梯）
    public WanderNode() { }
    public WanderNode(string floor, double x, double z, MoveKind move, double t, int? car = null) { Floor = floor; X = x; Z = z; Move = move; T = t; Car = car; }
}

/// 電梯車廂的一段移動（秒＝從行程出發算起）：空車先開到搭乘樓層、再載人到目的層，畫面照這個播車廂（10-22 Kang：搭電梯不要破圖）
public sealed record WanderCarMove(int Car, string From, string To, double Start, double End)
{
    public int Car { get; set; } = Car;
    public string From { get; set; } = From;       // 樓層 id
    public string To { get; set; } = To;
    public double Start { get; set; } = Start;
    public double End { get; set; } = End;
}

/// 一部電梯現在停在哪、到什麼時候有人在用（排程用；下一次刷新帶回來）
public sealed record WanderCar(string Floor, DateTime FreeAt)
{
    public string Floor { get; set; } = Floor;
    public DateTime FreeAt { get; set; } = FreeAt;
}

/// 一趟行程（拜訪／茶水角是來回一趟，含中間停留；上頂樓、回座位是單程）
public sealed record WanderTrip
{
    public string Sid { get; set; } = "";
    public DateTime Start { get; set; }
    public List<WanderNode> Nodes { get; set; } = new();
    public WanderSpot Dest { get; set; } = WanderSpot.desk;     // 這趟的目的地（停留的地方）
    public WanderSpot Final { get; set; } = WanderSpot.desk;    // 走完之後待哪（來回的＝.desk）
    public List<WanderCarMove> CarMoves { get; set; } = new();  // 這趟用到的電梯車廂移動（含空車去接人）
    public double duration => Nodes.Count == 0 ? 0 : Nodes[^1].T;
    public DateTime end => Start.AddSeconds(duration);

    public WanderTrip() { }
    public WanderTrip(string sid, DateTime start, List<WanderNode> nodes, WanderSpot dest, WanderSpot final) { Sid = sid; Start = start; Nodes = nodes; Dest = dest; Final = final; }

    /// 第 t 秒在哪（畫面在視窗重新可見、或測試 instant 模式時直接定位用）。電梯／溜滑梯中途回傳出發那層（畫面自己決定怎麼畫車廂）
    public (string floor, double x, double z) position(double t)
    {
        if (Nodes.Count == 0) return ("", 0, 0);
        var first = Nodes[0];
        if (t <= first.T) return (first.Floor, first.X, first.Z);
        for (int i = 0; i + 1 < Nodes.Count; i++)
        {
            WanderNode a = Nodes[i], b = Nodes[i + 1];
            if (!(t < b.T)) continue;
            if (a.Floor != b.Floor || b.Move == WanderNode.MoveKind.teleport) return (a.Floor, a.X, a.Z);
            double k = b.T > a.T ? (t - a.T) / (b.T - a.T) : 1;
            return (a.Floor, a.X + (b.X - a.X) * k, a.Z + (b.Z - a.Z) * k);
        }
        var l = Nodes[^1];
        return (l.Floor, l.X, l.Z);
    }

    /// 停留開始的時間（instant 模式截圖：直接放到目的地）。電梯門口等車的 .wait 不算停留
    public double arriveAt
    {
        get
        {
            int w = Nodes.FindIndex(n => n.Move == WanderNode.MoveKind.wait && TowerLayout.doorIndex(n.X, n.Z) == null);
            if (w <= 0) return duration;
            return Nodes[w - 1].T;
        }
    }
}

public sealed record WanderState
{
    public WanderSpot Spot { get; set; }          // 行程走完之後待哪
    public WanderTrip? Trip { get; set; }         // 進行中的行程（走完就清掉）
    public WanderState(WanderSpot spot, WanderTrip? trip = null) { Spot = spot; Trip = trip; }
    public bool moving(DateTime now) => Trip is { } t && now < t.end;
}

/// 一個角色（畫面那邊從 Islands／卡片組出來）
public sealed record WanderPerson(string Sid, string Floor, Mood Mood, int Seat, int Seats);

public enum WanderMode { animate, instant, off }

public sealed record WanderPlan
{
    public Dictionary<string, WanderState> States { get; set; } = new();
    public List<WanderTrip> Started { get; set; } = new();    // 這次刷新新出發的（畫面要播）
    public List<string> Snapped { get; set; } = new();        // 這次直接瞬移的（畫面直接放到 spot，不播）
    public List<WanderCar> Cars { get; set; } = new();        // 兩部電梯的狀態（下一次 plan 傳回來）
    public int movingCount => States.Values.Count(s => s.Trip != null);
}

/// 樓層內的座標（模組本地）。10-20 UI/UX 優化（UIUX優化規劃.md §3.1）：模組 12×5.6；
/// x：左端電梯門 −6…−5.3、協作區 −5.3…−2.3、工作區 −2.3…2.5、休憩角 2.5…5.3、右端 5.3…6；
/// z：後帶 −2.8…−1.75、中帶（桌子）−1.75…1.1、前帶（走道、矮家具）1.1…2.8。
public static class TowerLayout
{
    public const double aisleZ = 1.45;
    public static readonly (double x, double z) elevatorDoor = (-5.7, -1.3);
    public static readonly (double x, double z) elevator = (-7.05, -1.3);
    /// 兩部電梯（10-22 Kang）：車廂中心、各層電梯門口；第 0 部＝原本那部（elevator／elevatorDoor）
    public static readonly (double x, double z)[] elevators = { (-7.05, -1.3), (-7.05, -2.9) };
    public static readonly (double x, double z)[] elevatorDoors = { (-5.7, -1.3), (-5.7, -2.9) };
    /// 這個點是第幾部電梯的門口（不是門口 ⇒ nil）：分辨「門口等車」的 .wait 和目的地的停留
    public static int? doorIndex(double x, double z)
    {
        int i = Array.FindIndex(elevatorDoors, d => Math.Abs(d.x - x) < 1e-6 && Math.Abs(d.z - z) < 1e-6);
        return i < 0 ? null : i;
    }
    public static readonly (double x, double z) slideDoor = (5.5, TowerSpec.back + 0.55);   // 後牆右端的門（溜滑梯在後牆後面）
    public static readonly (double x, double z) slideTop = (5.4, TowerSpec.back + 0.5);     // 頂樓溜滑梯入口
    public static readonly (double x, double z)[] lounge = { (3.0, 1.1), (4.5, 0.9) };       // 休憩角（單人椅後面、落地燈旁）
    /// 椅子（角色）在桌子後方幾公尺（角色放大 1.6 倍：身體深 0.8，0.62 會穿進桌子）
    public const double chairBack = 0.72;
    /// 後段走道（前組桌的人 z −1.02、後組桌的人 z −2.18 之間）：座位在 z < 0 的人走這條去電梯，前面的人走 aisleZ
    public const double backAisleZ = -1.6;

    /// 自由座（10-22 Kang：員工不用全部面向鏡頭、辦公室不要那麼死板；加深的後段要用上，各自有各自的位置）：x、z＝桌心，a＝人面向（0＝面向鏡頭 +z、π＝背對、−π/2＝面向左牆、π/2＝面向右牆）。
    /// 桌位有：前組／後組各一組面對面四人桌、左右側牆各兩張單人桌。排序是「先分散」：人少的時候一人一區（前、後、右牆、左牆），人多了才併桌
    public static readonly (double x, double z, double a)[] freeDesks =
    {
        (-0.7, -0.3, 0), (-1.5, -4.3, 0), (2.6, -2.6, Math.PI / 2), (-4.4, -4.6, -Math.PI / 2),     // 一人一區：前、後、右牆、左牆
        (-0.7, 0.4, Math.PI), (-1.5, -3.6, Math.PI), (0.9, -0.3, 0), (0.1, -4.3, 0),               // 併桌：前組、後組
        (2.6, -4.4, Math.PI / 2), (-4.4, -3.0, -Math.PI / 2), (0.9, 0.4, Math.PI), (0.1, -3.6, Math.PI),
    };

    /// 每層從不同的區開始坐（10-22 Kang：每層第一個人都在同一個位置，往上看疊成一直排、很死板）：
    /// 用樓層 id 雜湊出 0–3 的位移，每 4 張一組各自輪轉（同一層永遠一樣，不會每次刷新換座位）
    public static int spin(string floor)
    {
        if (floor.Length == 0) return 0;
        ulong h = 0xcbf29ce484222325;
        foreach (var b in System.Text.Encoding.UTF8.GetBytes(floor)) { h ^= b; h = unchecked(h * 0x00000100000001B3); }
        return (int)(h % 4);
    }
    /// 桌心位置與朝向（12 張以內）；floor＝樓層 id（決定這層從哪一區開始坐）
    public static (double x, double z, double a) desk(int i0, int n, string floor = "")
    {
        int i = Math.Min(Math.Max(i0, 0), freeDesks.Length - 1), k = spin(floor);
        return freeDesks[i / 4 * 4 + (i % 4 + k) % 4];
    }

    /// 角色坐的位置（桌子後方 chairBack，順著朝向）。13 個以上：多的站前帶（z 2.2，間距 1.0，面向鏡頭）
    public static (double x, double z, double a) seat(int i, int n, string floor = "")
    {
        if (i >= 12)
        {
            int k = i - 12, m = n - 12;
            return (0.1 + (k - (m - 1) / 2.0) * 1.0, 2.2, 0);
        }
        var d = desk(i, Math.Min(n, 12), floor);
        return (d.x - chairBack * Math.Sin(d.a), d.z - chairBack * Math.Cos(d.a), d.a);
    }

    /// 從座位走到走道前先繞開自己的桌子：側牆桌先往房間中間退 0.7；後組面向鏡頭的人（桌子擋在前面）往桌子外側繞 1.0
    public static double? exitX((double x, double z, double a) s)
    {
        if (Math.Abs(Math.Sin(s.a)) > 0.5) return s.x - 0.7 * Math.Sin(s.a);
        if (Math.Cos(s.a) > 0.5 && s.z < backAisleZ - 1) return s.x < -0.7 ? s.x - 1.1 : s.x + 0.9;
        return null;
    }
    /// 座位 → 走道的折線（不含座位本身）；回座位時倒過來走
    public static List<(double x, double z)> toAisle((double x, double z, double a) s)
    {
        double z = aisle(s);
        if (exitX(s) is { } x) return new() { (x, s.z), (x, z) };
        return new() { (s.x, z) };
    }

    /// 這個座位去電梯／回座位走哪條走道（z）
    public static double aisle((double x, double z, double a) s) => s.z < 0 ? backAisleZ : aisleZ;

    /// 角色站著的身體範圍：寬 1.55（含手）、深 0.82（10-22 實測包圍盒）⇒ 站位左右至少隔 1.7、離家具前緣 0.45，不然人疊人、插進沙發
    /// 頂樓 7 個休息站位（長椅前 2、咖啡吧前 2、棚架下 3），多的排在植栽槽前
    public static (double x, double z) roofSlot(int i)
    {
        (double, double)[] fix = { (-4.4, 1.1), (-2.7, 1.1),           // 長椅前
                                   (2.4, 0.65), (4.1, 0.65),           // 咖啡吧前
                                   (-1.0, 0.1), (0.7, 0.2), (-0.2, 1.55) };   // 棚架下
        if (i < fix.Length) return fix[i];
        int k = i - fix.Length;
        return (-4.6 + (k % 6) * 1.75, -1.4);
    }

    /// 一樓咖啡館（大樓後段 z −5.45…−2.8，10-22 加深）：從電梯門往後走到這條走道再橫過去
    public static double cafeWalkZ => TowerSpec.backInner + 2.15;
    public const double cafeEntryX = -5.0;
    /// 咖啡館 6 個站位（沙發前 2、吧台前 2、立食桌兩側 2），多的排在走道；a＝面向（0＝面向鏡頭、π＝背對）
    public static (double x, double z, double a) cafeSlot(int i)
    {
        // z 都從後牆內側（bz）算：沙發前緣 bz+0.85、吧台前緣 bz+0.8、立食桌 bz+1.15
        double bz = TowerSpec.backInner;
        (double, double, double)[] fix = { (-4.4, bz + 1.4, 0), (-2.65, bz + 1.4, 0),            // 沙發前
                                           (2.05, bz + 1.3, Math.PI), (3.8, bz + 1.3, Math.PI),  // 吧台前（背對鏡頭看咖啡師）
                                           (-0.95, bz + 1.7, 0.4), (0.95, bz + 1.7, -0.4) };     // 立食桌兩側
        if (i < fix.Length) return fix[i];
        int k = i - fix.Length;
        return (-4.4 + (k % 3) * 1.75, bz + 2.45, 0);
    }

    // MARK: 地下室 B1（10-22 Kang：員工也可以搭電梯到 B1 看神經網路）

    /// B1 的樓層 id（TowerPlan 裡沒有這層：B1 不算樓層號、不搬家，固定在大廳正下方）
    public const string b1Floor = "b1";
    /// B1 地坪（世界 y）。⚠ 要跟網頁 scene/basement.js 的 floorY 同步（Mac：ShoWorkAgent/OfficeBasement.floorY）
    public const double b1Y = -5.6;
    /// B1 模組原點（樓板底，跟 TowerFloor.y 同一種量法：地坪＝原點＋樓板＋0.01）
    public static double b1Origin => b1Y - TowerSpec.slab - 0.01;
    /// 圖譜中心（模組本地 x、z）：機房正中間（模組 z 中線）
    public static (double x, double z) b1Center => (0, TowerSpec.front - TowerSpec.depth / 2);
    /// 內圈半徑（圖譜半徑 2.2 外面一點，看得到整團）、外圈半徑、繞行半徑（兩圈中間）
    public const double b1Ring = 3.0, b1Outer = 4.1, b1WalkR = 3.55;
    /// 從電梯門口進機房先走到這條線（x）再繞圈：左牆機櫃讓出來的門口空地
    public const double b1EntryX = -4.6;

    /// 站位的角度 φ（弧度）：0＝圖譜正後方（z 小，人面向鏡頭看圖譜）、±π/2＝左右兩側、π＝前方（擋鏡頭，最後才站）。
    /// 內圈 8 個（間距 2.3）；外圈 6 個只在兩側和前方，跟內圈錯開半格、站位互相隔 1.7 以上
    static readonly double[] b1Inner = new[] { 0, -0.25, 0.25, -0.5, 0.5, -0.75, 0.75, 1 }.Select(x => x * Math.PI).ToArray();
    static readonly double[] b1OuterAngles = new[] { 0.375, -0.375, 0.625, -0.625, 0.875, -0.875 }.Select(x => x * Math.PI).ToArray();
    /// 前帶兩個角落（玻璃前、兩側機櫃前；外圈前方站位的外側）：第 15、16 個人
    static readonly (double x, double z)[] b1Front = { (-3.5, 2.35), (3.5, 2.35) };
    /// 第 i 個站位在哪個角度、哪個半徑；nil＝前帶角落（b1Front）。
    /// 超過 16 人（極少見）：站到兩圈中間（外圈的角度、繞行半徑），會跟旁邊的人擠在一起
    static (double phi, double r)? b1Polar(int i)
    {
        if (i < b1Inner.Length) return (b1Inner[i], b1Ring);
        int k = i - b1Inner.Length;
        if (k < b1OuterAngles.Length) return (b1OuterAngles[k], b1Outer);
        int f = k - b1OuterAngles.Length;
        if (f < b1Front.Length) return null;
        return (b1OuterAngles[(f - b1Front.Length) % b1OuterAngles.Length], b1WalkR);
    }
    /// 總共幾個不擠的站位
    public static int b1Capacity => b1Inner.Length + b1OuterAngles.Length + b1Front.Length;
    /// 圓上的點（φ 的定義同上）
    static (double x, double z) b1Point(double phi, double r)
    {
        var c = b1Center;
        return (c.x + r * Math.Sin(phi), c.z - r * Math.Cos(phi));
    }
    /// B1 站位：x、z（模組本地）＋a＝面向（一律面向圖譜中心）
    public static (double x, double z, double a) b1Slot(int i)
    {
        var c = b1Center;
        (double x, double z) p;
        if (b1Polar(Math.Max(0, i)) is { } pr) p = b1Point(pr.phi, pr.r);
        else p = b1Front[(Math.Max(0, i) - b1Inner.Length - b1OuterAngles.Length) % b1Front.Length];
        return (p.x, p.z, Math.Atan2(c.x - p.x, c.z - p.z));
    }
    /// 電梯門口 → 站位的折線（不含門口）：先走到門口空地，沿繞行圈（兩圈中間）繞到站位那個角度，再往內／外一步到站位。
    /// 不從中間直穿（中間是投影台、上面浮著圖譜）；要繞半圈以上時走前方（前帶比後方機櫃前寬）
    public static List<(double x, double z)> b1Route(int i, (double x, double z) d)
    {
        var s = b1Slot(i);
        var out_ = new List<(double x, double z)> { (b1EntryX, d.z) };
        if (b1Polar(Math.Max(0, i)) is not { } pr)
        {
            // 前帶角落：從門口空地往前走到前帶再橫過去
            out_.Add((b1EntryX, s.z)); out_.Add((s.x, s.z));
            return out_;
        }
        double a0 = -Math.PI / 2;
        double delta = pr.phi - a0;
        while (delta >= Math.PI - 1e-9) delta -= 2 * Math.PI;       // 正好對面（φ＝π/2）⇒ 往負方向繞（經過前方）
        while (delta < -Math.PI - 1e-9) delta += 2 * Math.PI;
        int steps = Math.Max(1, (int)Math.Ceiling(Math.Abs(delta) / (Math.PI / 6)));
        for (int k = 0; k <= steps; k++) out_.Add(b1Point(a0 + delta * k / steps, b1WalkR));
        out_.Add((s.x, s.z));
        return out_;
    }
}

public static class WanderPlanner
{
    public const double departP = 0.125;          // 每次刷新出發機率（15 秒一次 ⇒ 平均每人 2 分鐘一趟；10-23 Kang 嫌死板，原 0.0625＝4 分鐘）
    public const int maxMoving = 3;               // 全棟同時在路上
    public const int maxDepartPerTick = 1;        // 每次刷新最多隨機出發幾人
    public const double walkSpeed = 1.1;          // m/s
    public const double elevatorSpeed = 2.4;      // m/s
    public const double slidePerFloor = 1.2;      // 秒／層
    /// 電梯／溜滑梯那一段超過這麼久就換成瞬移（12 秒 ≈ 電梯 8 層、溜滑梯 10 層，貼近規範「例如 10 層以上」的意思）
    public const double maxRide = 12.0;
    public const double bucket = 15;              // 隨機種子的時段長度（秒）
    public const double stagger = 2.5;            // 同層同時出發：每人錯開幾秒（出發前站在原地）

    // MARK: 可重現的亂數

    /// FNV-1a 64 → SplitMix64 → [0, 1)
    public static double rand(string sid, long slot, string salt)
    {
        ulong h = 0xcbf29ce484222325;
        foreach (var b in System.Text.Encoding.UTF8.GetBytes($"{sid}|{slot}|{salt}")) { h ^= b; h = unchecked(h * 0x00000100000001B3); }
        unchecked
        {
            h += 0x9E3779B97F4A7C15;
            ulong z = h;
            z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9;
            z = (z ^ (z >> 27)) * 0x94D049BB133111EB;
            z ^= z >> 31;
            return (double)(z >> 11) / (double)(1UL << 53);
        }
    }

    // MARK: 決策

    /// 休息去哪：每個人固定偏好（不會每次刷新換來換去）。晴天三選一：頂樓／一樓咖啡館／地下室 B1 各約三分之一；
    /// 下雨（或沒有頂樓）不上頂樓：偏好咖啡館、B1 的照舊，偏好頂樓的改去他固定的室內點（咖啡館或 B1 一半一半）。
    /// B1 在大廳正下方、從大廳的電梯下去 ⇒ 有大廳才有 B1（`cafe`＝有大廳）
    static WanderSpot? restSpot(WanderPerson p, bool rain, bool roof, bool cafe)
    {
        bool b1 = cafe;
        int pref = Math.Min(2, (int)(rand(p.Sid, 0, "rest3") * 3));      // 0 頂樓、1 咖啡館、2 B1
        WanderSpot? indoor = !cafe ? null
            : pref == 1 ? WanderSpot.cafe(-1) : pref == 2 ? WanderSpot.b1(-1)
            : rand(p.Sid, 0, "indoor") < 0.5 ? WanderSpot.cafe(-1) : WanderSpot.b1(-1);
        if (rain || !roof) return indoor;
        if (pref == 0 || !b1) return WanderSpot.roof(-1);
        return indoor;
    }

    /// `previous`＝上次的 states；`visible`＝視窗看得到（被蓋住／縮小就 false：不出發、進行中的直接落地）
    /// `rain`＝現在下雨（休息的人不上頂樓、已經在頂樓的下到偏好的室內點：一樓咖啡館或 B1）
    /// `cars`＝上一次 plan 的 `WanderPlan.cars`（兩部電梯停哪、何時有空；沒給＝都停一樓、現在有空）
    public static WanderPlan plan(List<WanderPerson> people, TowerPlan tower, IReadOnlyDictionary<string, WanderState> previous, DateTime now,
                                  bool visible = true, WanderMode mode = WanderMode.animate, bool rain = false, List<WanderCar>? cars0 = null)
    {
        long slot = (long)(MacMirror.Seconds(now) / bucket);
        var out_ = new WanderPlan();
        var roof = tower.floor("roof"); var lobby = tower.floor("lobby");
        WanderSpot? rest(WanderPerson p) => restSpot(p, rain, roof != null, lobby != null);
        // 1. 舊狀態：走完的清掉；人不在了就丟掉；看不到／關掉閒晃 ⇒ 進行中的直接落地
        foreach (var p in people)
        {
            var s = previous.TryGetValue(p.Sid, out var prev) ? prev with { } : new WanderState(p.Mood == Mood.Idle ? rest(p) ?? WanderSpot.desk : WanderSpot.desk);
            if (s.Trip is { } t && (now >= t.end || !visible || mode == WanderMode.off)) { s.Trip = null; if (now < t.end) out_.Snapped.Add(p.Sid); }
            // 拜訪的對象樓層不在了（降樓）⇒ 直接回座位
            if (s.Spot.Case == "visit" && tower.floor(s.Spot.Floor ?? "") == null) { s = new WanderState(WanderSpot.desk); out_.Snapped.Add(p.Sid); }
            out_.States[p.Sid] = s;
        }
        // 頂樓站位：先保留已經在頂樓的，-1（新來的）之後再發
        HashSet<int> taken(string c) => out_.States.Values.Where(s => s.Spot.Case == c && s.Spot.Slot >= 0).Select(s => s.Spot.Slot).ToHashSet();
        var roofTaken = taken("roof"); var cafeTaken = taken("cafe"); var b1Taken = taken("b1");
        static int free(HashSet<int> t) { int i = 0; while (t.Contains(i)) i++; t.Add(i); return i; }
        int freeRoofSlot() => free(roofTaken);
        int freeCafeSlot() => free(cafeTaken);
        int freeB1Slot() => free(b1Taken);
        var sortedPeople = people.OrderBy(p => p.Sid, StringComparer.Ordinal).ToList();
        foreach (var p in sortedPeople)
        {
            var sp = out_.States[p.Sid].Spot;
            if (sp.Case == "roof" && sp.Slot < 0) out_.States[p.Sid].Spot = WanderSpot.roof(freeRoofSlot());
            if (sp.Case == "cafe" && sp.Slot < 0) out_.States[p.Sid].Spot = WanderSpot.cafe(freeCafeSlot());
            if (sp.Case == "b1" && sp.Slot < 0) out_.States[p.Sid].Spot = WanderSpot.b1(freeB1Slot());
        }
        int moving = out_.States.Values.Count(s => s.moving(now));
        bool canAnimate = visible && mode != WanderMode.off;
        // 10-20 第 4 棒：同一次刷新、同一層一起出發的人走同一條走道會疊成一團 ⇒ 第 2、3 個晚 stagger 秒出發
        var sameFloor = new Dictionary<string, int>();
        // 電梯：播不了（看不到／關掉）⇒ 路上的都落地了，車廂也當作現在有空
        var cars = initialCars(cars0 ?? new(), now);
        if (!canAnimate) for (int c = 0; c < cars.Count; c++) if (cars[c].FreeAt > now) cars[c] = cars[c] with { FreeAt = now };
        out_.Cars = cars.ToList();
        // 排電梯＋組成行程（依呼叫順序排，同一次刷新的行程不會搶同一部車）
        WanderTrip makeTrip(string sid, DateTime start, WanderSpot dest, WanderSpot final, Func<int, List<WanderNode>> route)
        {
            var s = schedule(start, cars, tower, route);
            out_.Cars = cars.ToList();
            return new WanderTrip(sid, start, s.nodes, dest, final) { CarMoves = s.moves };
        }

        // 發一趟行程；超過同時上限或不能播 ⇒ 直接瞬移到 final。`route(c)`＝走第 c 部電梯的路線（instant 模式＝nil）
        void go(WanderPerson p, WanderSpot dest, WanderSpot final, Func<int, List<WanderNode>>? route)
        {
            List<WanderNode>? nodes = canAnimate && moving < maxMoving && route != null ? route(0) : null;
            if (nodes != null && nodes.Count > 1)
            {
                var from = nodes[0].Floor; int k = sameFloor.GetValueOrDefault(from);
                sameFloor[from] = k + 1;
                var trip = makeTrip(p.Sid, now.AddSeconds(k * stagger), dest, final, route!);
                out_.States[p.Sid] = new WanderState(final, trip);
                out_.Started.Add(trip);
                moving += 1;
            }
            else
            {
                out_.States[p.Sid] = new WanderState(final);
                out_.Snapped.Add(p.Sid);
            }
        }
        bool instant = mode == WanderMode.instant;

        // 2. 狀態優先的必走（不受機率限制，但受同時 3 人限制）
        foreach (var p in sortedPeople)
        {
            var s = out_.States[p.Sid];
            switch (p.Mood)
            {
                case Mood.Waiting:
                    // 等你回答：一定在桌前。正在路上（含來回趟）也直接拉回
                    if (!s.Spot.isDesk || s.Trip != null)
                    {
                        out_.States[p.Sid] = new WanderState(WanderSpot.desk);
                        if (!out_.Snapped.Contains(p.Sid)) out_.Snapped.Add(p.Sid);
                    }
                    break;
                case Mood.Working or Mood.Stuck or Mood.Asleep:
                    if (s.Trip != null || s.Spot.isDesk) break;      // 在路上的（來回趟）走完自然回座位
                    if (s.Spot.isRoof)
                    {
                        int i = s.Spot.Slot; roofTaken.Remove(i);
                        go(p, WanderSpot.desk, WanderSpot.desk, instant ? null : _ => fromRoof(p, i, tower));
                    }
                    else if (s.Spot.isCafe)
                    {
                        int i = s.Spot.Slot; cafeTaken.Remove(i);
                        go(p, WanderSpot.desk, WanderSpot.desk, instant ? null : c => fromCafe(p, i, tower, c));
                    }
                    else if (s.Spot.isB1)
                    {
                        int i = s.Spot.Slot; b1Taken.Remove(i);
                        go(p, WanderSpot.desk, WanderSpot.desk, instant ? null : c => fromB1(p, i, tower, c));
                    }
                    else
                    {
                        out_.States[p.Sid] = new WanderState(WanderSpot.desk); out_.Snapped.Add(p.Sid);
                    }
                    break;
                case Mood.Idle:
                    if (s.Trip != null) break;
                    if (s.Spot.isRoof)
                    {
                        // 下雨了（或頂樓不在了）：頂樓的人搭電梯下到他偏好的室內點（一樓咖啡館或 B1）
                        if (!(rain || roof == null) || lobby == null || rest(p) is not { } r0) break;
                        int i = s.Spot.Slot; roofTaken.Remove(i);
                        if (r0.isB1)
                        {
                            int j = freeB1Slot();
                            go(p, WanderSpot.b1(j), WanderSpot.b1(j), instant ? null : c => roofToB1(i, j, tower, c));
                        }
                        else
                        {
                            int j = freeCafeSlot();
                            go(p, WanderSpot.cafe(j), WanderSpot.cafe(j), instant ? null : c => roofToCafe(i, j, tower, c));
                        }
                        break;
                    }
                    if (s.Spot.isIndoorRest || rest(p) is not { } r) break;
                    if (r.isCafe)
                    {
                        int i = freeCafeSlot();
                        go(p, WanderSpot.cafe(i), WanderSpot.cafe(i), instant ? null : c => toCafe(p, i, tower, c));
                    }
                    else if (r.isB1)
                    {
                        int i = freeB1Slot();
                        go(p, WanderSpot.b1(i), WanderSpot.b1(i), instant ? null : c => toB1(p, i, tower, c));
                    }
                    else
                    {
                        int i = freeRoofSlot();
                        go(p, WanderSpot.roof(i), WanderSpot.roof(i), instant ? null : c => toRoof(p, i, tower, c));
                    }
                    break;
                case Mood.Finished:
                    if (s.Trip != null) break;
                    if (s.Spot.isRoof)        // 從休息變成做完：回座位
                    {
                        int i = s.Spot.Slot; roofTaken.Remove(i);
                        go(p, WanderSpot.desk, WanderSpot.desk, instant ? null : _ => fromRoof(p, i, tower));
                    }
                    else if (s.Spot.isCafe)
                    {
                        int i = s.Spot.Slot; cafeTaken.Remove(i);
                        go(p, WanderSpot.desk, WanderSpot.desk, instant ? null : c => fromCafe(p, i, tower, c));
                    }
                    else if (s.Spot.isB1)
                    {
                        int i = s.Spot.Slot; b1Taken.Remove(i);
                        go(p, WanderSpot.desk, WanderSpot.desk, instant ? null : c => fromB1(p, i, tower, c));
                    }
                    break;
            }
        }

        // 3. 隨機閒晃：只有「做完了你還沒看」、在座位上、沒在路上的
        if (!canAnimate) return out_;
        int departed = 0;
        var hosts = people.Where(h => h.Mood is Mood.Working or Mood.Stuck or Mood.Waiting or Mood.Finished
                                      && out_.States.GetValueOrDefault(h.Sid)?.Spot.isDesk == true && out_.States.GetValueOrDefault(h.Sid)?.Trip == null).ToList();
        foreach (var p in sortedPeople.Where(p => p.Mood == Mood.Finished))
        {
            if (!(departed < maxDepartPerTick && moving < maxMoving)) break;
            if (out_.States.GetValueOrDefault(p.Sid) is not { } s || !s.Spot.isDesk || s.Trip != null) continue;
            if (!(rand(p.Sid, slot, "go") < departP)) continue;
            var others = hosts.Where(h => h.Floor != p.Floor && h.Sid != p.Sid).ToList();
            WanderTrip trip;
            if (others.Count > 0 && rand(p.Sid, slot, "kind") < 0.5)
            {
                var h = others[(int)(rand(p.Sid, slot, "host") * others.Count) % others.Count];
                double stay = 8 + rand(p.Sid, slot, "stay") * 7;
                trip = makeTrip(p.Sid, now, WanderSpot.visit(h.Floor, h.Sid), WanderSpot.desk, c => visit(p, h, stay, tower, c));
            }
            else
            {
                int k = rand(p.Sid, slot, "lounge") < 0.5 ? 0 : 1;
                double stay = 10 + rand(p.Sid, slot, "stay") * 15;
                trip = new WanderTrip(p.Sid, now, lounge(p, k, stay), WanderSpot.lounge(k), WanderSpot.desk);
            }
            out_.States[p.Sid] = new WanderState(WanderSpot.desk, trip);
            out_.Started.Add(trip);
            moving += 1; departed += 1;
        }
        return out_;
    }

    // MARK: 路線（模組本地座標）

    static double r2(double x) => Math.Round(x * 100, MidpointRounding.AwayFromZero) / 100;
    static double up2(double x) => Math.Ceiling(x * 100) / 100;

    /// 沿折線排時間：走路 1.1 m/s
    static List<WanderNode> timed(List<(string floor, double x, double z, WanderNode.MoveKind move)> pts, TowerPlan tower, double startT = 0)
    {
        var out_ = new List<WanderNode>();
        double t = startT;
        for (int i = 0; i < pts.Count; i++)
        {
            var p = pts[i];
            if (i > 0)
            {
                var a = out_[i - 1];
                switch (p.move)
                {
                    case WanderNode.MoveKind.walk or WanderNode.MoveKind.start: t += Math.Sqrt((p.x - a.X) * (p.x - a.X) + (p.z - a.Z) * (p.z - a.Z)) / walkSpeed; break;
                    case WanderNode.MoveKind.elevator: t += Math.Abs(floorY(p.floor, tower) - floorY(a.Floor, tower)) / elevatorSpeed; break;
                    case WanderNode.MoveKind.slide: t += floorsBetween(a.Floor, p.floor, tower) * slidePerFloor; break;
                }
            }
            out_.Add(new WanderNode(p.floor, p.x, p.z, i == 0 ? WanderNode.MoveKind.start : p.move, r2(t)));
        }
        return capLeg(out_);
    }

    /// 電梯／溜滑梯那段太久（超過 maxRide）：換成瞬移（規範 §4.3「走到電梯口 → 瞬移到目的層電梯口」），後面的時間往前收
    static List<WanderNode> capLeg(List<WanderNode> n)
    {
        var out_ = n.Select(x => x with { }).ToList();
        double removed = 0.0;
        for (int i = 1; i < n.Count; i++)
        {
            double seg = n[i].T - n[i - 1].T;
            if ((n[i].Move == WanderNode.MoveKind.elevator || n[i].Move == WanderNode.MoveKind.slide) && seg > maxRide)
            {
                removed += seg;
                out_[i].Move = WanderNode.MoveKind.teleport;
            }
            out_[i].T = r2(n[i].T - removed);
        }
        return out_;
    }

    // MARK: 電梯排程（10-22 Kang：電梯兩部、搭電梯不要破圖、沒有電梯要等）

    static (double x, double z) cab(int c) => TowerLayout.elevators[Math.Min(Math.Max(c, 0), TowerLayout.elevators.Length - 1)];
    static (double x, double z) door(int c) => TowerLayout.elevatorDoors[Math.Min(Math.Max(c, 0), TowerLayout.elevatorDoors.Length - 1)];

    /// 沒給（第一次刷新）：每部都停一樓、現在有空；少給的補齊
    static List<WanderCar> initialCars(List<WanderCar> given, DateTime now)
    {
        var cars = given.Select(c => c with { }).ToList();
        while (cars.Count < TowerLayout.elevators.Length) cars.Add(new WanderCar("lobby", now));
        return cars.Take(TowerLayout.elevators.Length).ToList();
    }

    /// 樓層的高度（模組原點 y）：B1 不在 TowerPlan 裡 ⇒ 用 TowerLayout.b1Origin；找不到的樓層當 0（大廳）
    static double floorY(string id, TowerPlan tower) => id == TowerLayout.b1Floor ? TowerLayout.b1Origin : tower.floor(id)?.Y ?? 0;

    /// 車廂在兩層之間開幾秒（跟人搭電梯同一個速度；往上取到 0.01 秒）
    static double carTravel(string a, string b, TowerPlan tower) => up2(Math.Abs(floorY(b, tower) - floorY(a, tower)) / elevatorSpeed);

    /// 排一趟行程的電梯：`build(c)`＝走第 c 部電梯的路線。挑「最早能上車」的那部（一樣早挑編號小的），
    /// 車廂先從它停的樓層空車開過來（最早在它有空、而且這趟出發之後才動），人到門口車還沒到就在門口 .wait 等，後面的節點往後推。
    /// 一部車一次只載一趟（不共乘）：來回的行程回程也用同一部，車在目的層等他，到回程結束才放出來。
    /// 瞬移段（capLeg 換掉的）不是 .elevator，不佔車。路線裡沒有電梯段 ⇒ 原樣回傳、不動車
    static (List<WanderNode> nodes, List<WanderCarMove> moves) schedule(DateTime start, List<WanderCar> cars, TowerPlan tower, Func<int, List<WanderNode>> build)
    {
        var @base = build(0);
        if (!@base.Any(n => n.Move == WanderNode.MoveKind.elevator)) return (@base, new());
        // 1. 挑車：第一段電梯的上車時間＝max(走到門口, 車開過來)
        (int c, DateTime board, List<WanderNode> nodes)? best = null;
        for (int c = 0; c < cars.Count; c++)
        {
            var n = c == 0 ? @base : build(c);
            int i = n.FindIndex(x => x.Move == WanderNode.MoveKind.elevator);
            if (i < 1) continue;
            int d = i >= 2 ? i - 2 : i - 1;
            var ready = (cars[c].FreeAt > start ? cars[c].FreeAt : start).AddSeconds(carTravel(cars[c].Floor, n[i - 1].Floor, tower));
            var walk = start.AddSeconds(n[d].T);
            var board = walk > ready ? walk : ready;
            if (best == null || board < best.Value.board) best = (c, board, n);
        }
        if (best is not { } pick) return (@base, new());
        int cc = pick.c; var nodes = pick.nodes;
        var car = cars[cc] with { };
        var out_ = new List<WanderNode>(); var moves = new List<WanderCarMove>();
        // 每段電梯的門口（電梯段往前兩個點：門口 → 車廂 → 電梯段）
        var doorOf = new Dictionary<int, int>();
        for (int i = 1; i < nodes.Count; i++) if (nodes[i].Move == WanderNode.MoveKind.elevator) doorOf[i >= 2 ? i - 2 : i - 1] = i;
        double shift = 0.0;
        for (int k = 0; k < nodes.Count; k++)
        {
            var n = nodes[k] with { };
            n.T = r2(n.T + shift);
            if (n.Move == WanderNode.MoveKind.elevator && k >= 1)
            {
                // 載人那段：從上車點（前一個點）開到這層
                n.Car = cc;
                var from = out_[^1];
                moves.Add(new WanderCarMove(cc, from.Floor, n.Floor, from.T, n.T));
                car.Floor = n.Floor;
                car.FreeAt = start.AddSeconds(n.T);
            }
            out_.Add(n);
            if (!doorOf.TryGetValue(k, out var di)) continue;
            // 門口：車要先開到這層（空車），還沒到就在門口等
            var boardFloor = nodes[di - 1].Floor;
            double leave = up2(((car.FreeAt > start ? car.FreeAt : start) - start).TotalSeconds);
            double ready = leave;
            if (car.Floor != boardFloor)
            {
                double travel = carTravel(car.Floor, boardFloor, tower);
                moves.Add(new WanderCarMove(cc, car.Floor, boardFloor, leave, leave + travel));
                ready = leave + travel;
                car.Floor = boardFloor;
            }
            if (ready > n.T + 0.0001)
            {
                double w = up2(ready - n.T);
                shift += w;
                out_.Add(new WanderNode(n.Floor, n.X, n.Z, WanderNode.MoveKind.wait, r2(n.T + w)));
            }
        }
        cars[cc] = car;
        return (out_, moves);
    }

    static int floorsBetween(string a, string b, TowerPlan tower)
    {
        int i = tower.Floors.FindIndex(f => f.Id == a), j = tower.Floors.FindIndex(f => f.Id == b);
        if (i < 0 || j < 0) return 1;
        return Math.Max(1, Math.Abs(i - j));
    }

    const WanderNode.MoveKind S = WanderNode.MoveKind.start, W = WanderNode.MoveKind.walk, E = WanderNode.MoveKind.elevator, SL = WanderNode.MoveKind.slide;
    static (string, double, double, WanderNode.MoveKind) P(string f, (double x, double z) p, WanderNode.MoveKind m) => (f, p.x, p.z, m);

    /// 座位 → 走道 → 電梯門 → 電梯（到目的層）→ 目的層電梯門 → 走道
    static List<(string floor, double x, double z, WanderNode.MoveKind move)> toElevator(WanderPerson p, int car = 0)
    {
        var s = TowerLayout.seat(p.Seat, p.Seats, p.Floor);
        double az = TowerLayout.aisle(s);
        var l = new List<(string, double, double, WanderNode.MoveKind)> { (p.Floor, s.x, s.z, S) };
        l.AddRange(TowerLayout.toAisle(s).Select(a => (p.Floor, a.x, a.z, W)));
        l.Add((p.Floor, -5.2, az, W)); l.Add(P(p.Floor, door(car), W)); l.Add(P(p.Floor, cab(car), W));
        return l;
    }

    static List<WanderNode> toRoof(WanderPerson p, int slot, TowerPlan tower, int car = 0)
    {
        var r = TowerLayout.roofSlot(slot);
        var l = toElevator(p, car);
        l.Add(P("roof", cab(car), E)); l.Add(P("roof", door(car), W)); l.Add(P("roof", r, W));
        return timed(l, tower);
    }

    /// 一樓：電梯門 → 往後走到咖啡館走道 → 站位
    static List<(string floor, double x, double z, WanderNode.MoveKind move)> cafeLeg(int i, int car = 0)
    {
        var c = TowerLayout.cafeSlot(i);
        return new() { P("lobby", door(car), W), ("lobby", TowerLayout.cafeEntryX, TowerLayout.cafeWalkZ, W),
                       ("lobby", c.x, TowerLayout.cafeWalkZ, W), ("lobby", c.x, c.z, W) };
    }

    static List<WanderNode> toCafe(WanderPerson p, int slot, TowerPlan tower, int car = 0)
    {
        var l = toElevator(p, car); l.Add(P("lobby", cab(car), E)); l.AddRange(cafeLeg(slot, car));
        return timed(l, tower);
    }

    /// 頂樓（下雨了）→ 電梯 → 一樓咖啡館
    static List<WanderNode> roofToCafe(int slot, int cafe, TowerPlan tower, int car = 0)
    {
        var r = TowerLayout.roofSlot(slot);
        var l = new List<(string, double, double, WanderNode.MoveKind)> { P("roof", r, S), P("roof", door(car), W), P("roof", cab(car), W), P("lobby", cab(car), E) };
        l.AddRange(cafeLeg(cafe, car));
        return timed(l, tower);
    }

    /// B1：電梯門 → 門口空地 → 繞圈 → 站位
    static List<(string floor, double x, double z, WanderNode.MoveKind move)> b1Leg(int i, int car = 0)
    {
        var f = TowerLayout.b1Floor;
        var l = new List<(string, double, double, WanderNode.MoveKind)> { P(f, door(car), W) };
        l.AddRange(TowerLayout.b1Route(i, door(car)).Select(x => (f, x.x, x.z, W)));
        return l;
    }

    /// 座位 → 電梯 → B1 → 站位
    static List<WanderNode> toB1(WanderPerson p, int slot, TowerPlan tower, int car = 0)
    {
        var l = toElevator(p, car); l.Add(P(TowerLayout.b1Floor, cab(car), E)); l.AddRange(b1Leg(slot, car));
        return timed(l, tower);
    }

    /// 頂樓（下雨了）→ 電梯 → B1
    static List<WanderNode> roofToB1(int slot, int b1, TowerPlan tower, int car = 0)
    {
        var r = TowerLayout.roofSlot(slot);
        var l = new List<(string, double, double, WanderNode.MoveKind)> { P("roof", r, S), P("roof", door(car), W), P("roof", cab(car), W), P(TowerLayout.b1Floor, cab(car), E) };
        l.AddRange(b1Leg(b1, car));
        return timed(l, tower);
    }

    /// 回到自己樓層：電梯 → 電梯門 → 走道 → 座位
    static void backToSeat(List<(string, double, double, WanderNode.MoveKind)> l, WanderPerson p, (double x, double z, double a) s, int car)
    {
        l.Add(P(p.Floor, cab(car), E)); l.Add(P(p.Floor, door(car), W));
        l.Add((p.Floor, -5.2, TowerLayout.aisle(s), W));
        l.AddRange(Enumerable.Reverse(TowerLayout.toAisle(s)).Select(a => (p.Floor, a.x, a.z, W)));
        l.Add((p.Floor, s.x, s.z, W));
    }

    /// B1 站位 → 原路繞回電梯 → 自己樓層 → 走道 → 座位
    static List<WanderNode> fromB1(WanderPerson p, int slot, TowerPlan tower, int car = 0)
    {
        var f = TowerLayout.b1Floor; var s = TowerLayout.seat(p.Seat, p.Seats, p.Floor);
        var back = Enumerable.Reverse(b1Leg(slot, car)).Select(x => (x.floor, x.x, x.z, W)).ToList();
        var l = new List<(string, double, double, WanderNode.MoveKind)> { (f, back[0].x, back[0].z, S) };
        l.AddRange(back.Skip(1));
        l.Add(P(f, cab(car), W));
        backToSeat(l, p, s, car);
        return timed(l, tower);
    }

    /// 咖啡館 → 電梯 → 自己樓層 → 走道 → 座位
    static List<WanderNode> fromCafe(WanderPerson p, int slot, TowerPlan tower, int car = 0)
    {
        var c = TowerLayout.cafeSlot(slot); var s = TowerLayout.seat(p.Seat, p.Seats, p.Floor);
        var l = new List<(string, double, double, WanderNode.MoveKind)>
        {
            ("lobby", c.x, c.z, S), ("lobby", c.x, TowerLayout.cafeWalkZ, W), ("lobby", TowerLayout.cafeEntryX, TowerLayout.cafeWalkZ, W),
            P("lobby", door(car), W), P("lobby", cab(car), W),
        };
        backToSeat(l, p, s, car);
        return timed(l, tower);
    }

    /// 頂樓 → 溜滑梯 → 自己樓層右門 → 走道 → 座位
    static List<WanderNode> fromRoof(WanderPerson p, int slot, TowerPlan tower)
    {
        var r = TowerLayout.roofSlot(slot); var s = TowerLayout.seat(p.Seat, p.Seats, p.Floor);
        var l = new List<(string, double, double, WanderNode.MoveKind)>
        {
            P("roof", r, S), P("roof", TowerLayout.slideTop, W), P(p.Floor, TowerLayout.slideDoor, SL), (p.Floor, 5.2, TowerLayout.aisle(s), W),
        };
        l.AddRange(Enumerable.Reverse(TowerLayout.toAisle(s)).Select(a => (p.Floor, a.x, a.z, W)));
        l.Add((p.Floor, s.x, s.z, W));
        return timed(l, tower);
    }

    /// 拜訪：搭電梯到對方樓層，站在對方桌旁 0.9 面向他，停留後原路（搭電梯）回
    static List<WanderNode> visit(WanderPerson p, WanderPerson h, double stay, TowerPlan tower, int car = 0)
    {
        var hs = TowerLayout.seat(h.Seat, h.Seats, h.Floor);
        double side = Math.Sin(hs.a) > 0.5 ? -0.9 : 0.9;          // 右牆的人（桌子在他右邊）站左邊
        var go = toElevator(p, car);
        go.Add(P(h.Floor, cab(car), E)); go.Add(P(h.Floor, door(car), W));
        go.Add((h.Floor, -5.2, TowerLayout.aisle(hs), W)); go.Add((h.Floor, hs.x + side, TowerLayout.aisle(hs), W)); go.Add((h.Floor, hs.x + side, hs.z, W));
        return roundTrip(timed(go, tower), stay);
    }

    /// 同層茶水角：座位 → 走道 → F1／F3，停留後原路回
    static List<WanderNode> lounge(WanderPerson p, int slot, double stay)
    {
        var s = TowerLayout.seat(p.Seat, p.Seats, p.Floor); var l = TowerLayout.lounge[slot];
        var pts = new List<(string, double, double, WanderNode.MoveKind)> { (p.Floor, s.x, s.z, S) };
        pts.AddRange(TowerLayout.toAisle(s).Select(a => (p.Floor, a.x, a.z, W)));
        pts.Add((p.Floor, l.x, TowerLayout.aisleZ, W)); pts.Add((p.Floor, l.x, l.z, W));
        return roundTrip(timed(pts, new TowerPlan()), stay);
    }

    /// 去程＋停留＋原路回（回程的每段花的時間跟去程一樣）
    static List<WanderNode> roundTrip(List<WanderNode> go, double stay)
    {
        if (go.Count == 0) return go;
        var last = go[^1];
        var out_ = go.ToList();
        double arrive = last.T + r2(stay);
        out_.Add(new WanderNode(last.Floor, last.X, last.Z, WanderNode.MoveKind.wait, arrive));
        var back = Enumerable.Reverse(go).ToList();
        for (int k = 1; k < back.Count; k++)
        {
            double seg = back[k - 1].T - back[k].T;
            out_.Add(new WanderNode(back[k].Floor, back[k].X, back[k].Z, back[k - 1].Move == WanderNode.MoveKind.start ? WanderNode.MoveKind.walk : back[k - 1].Move,
                                    r2(out_[^1].T + seg)));
        }
        return out_;
    }
}
