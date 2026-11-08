using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace ShoWork;

// Mac 版 Sources/ShoWorkCore/TowerTheme.swift 的逐行轉寫（11-02 P8）。
// 樓層主題（10-20，規範 §2、§5）：每層的風格由 AI 從主題庫挑（主題＋識別色＋2–3 件專屬擺設），結果快取在 board/themes/<專案>.json。
//   沒有結果前先用本地關鍵字評分（WorkSignature）挑一個，不阻塞畫面。
//   重新裝潢只在「一輪工作結束」那次刷新檢查：工作內容明顯變了（分數門檻＋Jaccard 門檻）、同專案 6 小時一次、全部合計 24 小時 8 次、
//   US$0.10／24h、失敗後 1 小時不再試、同時只跑一個。呼叫 claude -p（haiku）走你的訂閱；runner 可注入（測試不准真的呼叫）。
// Windows 的 runner 在 Board/Source/TowerSource.cs（找 claude.exe／claude.cmd，旗標跟 Mac 一樣）。

// MARK: - 主題庫

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum TowerTheme
{
    monitor, app_studio, library, print_shop, call_room, trading_desk, media_studio, design_studio,
    legal_room, ledger_room, game_lab, hw_lab, marketing, dispatch_room, drafting_room, general,
}

public static class TowerThemes
{
    public static readonly TowerTheme[] allCases = Enum.GetValues<TowerTheme>();
    public static string rawValue(this TowerTheme t) => t.ToString();
    public static TowerTheme? from(string? raw) => raw != null && Enum.TryParse<TowerTheme>(raw, out var t) && Enum.IsDefined(t) && !int.TryParse(raw, out _) ? t : null;
    static int index(TowerTheme t) => Array.IndexOf(allCases, t);

    public static string title(this TowerTheme t) => t switch
    {
        TowerTheme.monitor => "監控中心", TowerTheme.app_studio => "App 開發室", TowerTheme.library => "研究書房", TowerTheme.print_shop => "3D 列印工坊",
        TowerTheme.call_room => "秘書電話室", TowerTheme.trading_desk => "交易室", TowerTheme.media_studio => "攝影棚", TowerTheme.design_studio => "設計工作室",
        TowerTheme.legal_room => "法務室", TowerTheme.ledger_room => "財務帳房", TowerTheme.game_lab => "遊戲工作室", TowerTheme.hw_lab => "硬體實驗室",
        TowerTheme.marketing => "行銷室", TowerTheme.dispatch_room => "調度中心", TowerTheme.drafting_room => "建築製圖室", _ => "通用辦公",
    };

    /// 一句適用說明（放進提示詞）
    public static string blurb(this TowerTheme t) => t switch
    {
        TowerTheme.monitor => "看板、監控、常駐服務、log",
        TowerTheme.app_studio => "iOS/macOS/Android App、上架",
        TowerTheme.library => "研究、調查、寫報告、文件多於程式",
        TowerTheme.print_shop => "3D 列印、CAD、模型、外殼",
        TowerTheme.call_room => "LINE／信箱／電話代理、行事曆、提醒",
        TowerTheme.trading_desk => "股票、回測、投資工具",
        TowerTheme.media_studio => "影片、配音、分鏡、宣傳片",
        TowerTheme.design_studio => "介面設計、品牌、名片、排版",
        TowerTheme.legal_room => "合約、NDA、授權、條款",
        TowerTheme.ledger_room => "記帳、報價、發票、還款、預算",
        TowerTheme.game_lab => "遊戲、關卡、角色美術、撲克工具",
        TowerTheme.hw_lab => "藍牙、音訊、風扇、電路、韌體",
        TowerTheme.marketing => "社群貼文、廣告、官網、宣傳",
        TowerTheme.dispatch_room => "派車、派單、航班、行程、地圖",
        TowerTheme.drafting_room => "平面圖、室內設計、水電、建築",
        _ => "通用辦公（判斷不出來時用）",
    };

    /// 預設識別色（規範 §2.1）
    public static string accent(this TowerTheme t) => t switch
    {
        TowerTheme.monitor => "#5B8DB8", TowerTheme.app_studio => "#4E9C8F", TowerTheme.library => "#9C6B4E", TowerTheme.print_shop => "#C98B3C",
        TowerTheme.call_room => "#8C7BB5", TowerTheme.trading_desk => "#3F8F5A", TowerTheme.media_studio => "#B5525A", TowerTheme.design_studio => "#D08A6E",
        TowerTheme.legal_room => "#4A5A7A", TowerTheme.ledger_room => "#A88C3E", TowerTheme.game_lab => "#7A5FA8", TowerTheme.hw_lab => "#C2703A",
        TowerTheme.marketing => "#C56B86", TowerTheme.dispatch_room => "#3E8FA8", TowerTheme.drafting_room => "#6E8A6A", _ => "#8F8B85",
    };

    /// 可選擺設（AI 從這裡＋通用擺設挑 2–3 件；第一件、第二件是本地預設）
    public static string[] optionalProps(this TowerTheme t) => t switch
    {
        TowerTheme.monitor => new[] { "console", "server_rack", "wall_clock" },
        TowerTheme.app_studio => new[] { "standing_desk", "device_cart", "whiteboard" },
        TowerTheme.library => new[] { "long_table", "floor_lamp", "card_catalog", "globe" },
        TowerTheme.print_shop => new[] { "workbench", "filament_rack", "finished_shelf" },
        TowerTheme.call_room => new[] { "sofa", "side_table", "mail_rack", "switchboard" },
        TowerTheme.trading_desk => new[] { "quad_monitor", "bull_statue", "safe" },
        TowerTheme.media_studio => new[] { "softbox", "camera_tripod", "edit_bay" },
        TowerTheme.design_studio => new[] { "drafting_table", "material_shelf", "easel" },
        TowerTheme.legal_room => new[] { "file_cabinet", "law_shelf", "seal_desk" },
        TowerTheme.ledger_room => new[] { "wall_clock", "receipt_tray", "cashier_counter", "ledger_shelf" },
        TowerTheme.game_lab => new[] { "sofa", "sprite_wall", "controller_shelf", "trophy_shelf" },
        TowerTheme.hw_lab => new[] { "parts_wall", "soldering_station", "test_rig" },
        TowerTheme.marketing => new[] { "ring_light", "product_table", "sofa" },
        TowerTheme.dispatch_room => new[] { "flight_board", "key_cabinet", "wall_clock" },
        TowerTheme.drafting_room => new[] { "plan_chest", "model_plinth", "section_wall" },
        _ => new[] { "plant_low", "coffee_cart" },
    };

    /// 判斷關鍵字（規範 §2.1；10-20 UI/UX 優化 §4.3 修正）。純英數字的照「詞」比對，其他（中文、含 . / 空白 - 的）照子字串比對
    public static string[] keywords(this TowerTheme t) => t switch
    {
        TowerTheme.monitor => new[] { "monitor", "dashboard", "daemon", "launchd", "statusline", "fan", "fans", "wifi", "temperature", "監控", "看板", "守門", "溫度", "巡檢",
                                      "戰情", "command center", "menu bar", "menu-bar", "menubar", "terminal", "終端機", "mouse", "滑鼠", "螢幕控制", "screen control", "選單列" },
        TowerTheme.app_studio => new[] { "swiftui", "xcode", "ios", "iphone", "ipad", "android", "kotlin", "testflight", "app store", "info.plist", ".xcodeproj", "上架", "送審", "nfc" },
        TowerTheme.library => new[] { "research", "survey", "paper", "研究", "報告", "調查", "文獻" },
        TowerTheme.print_shop => new[] { "stl", "3mf", ".step", ".stp", "fusion", "blender", "picogk", "build123d", "cad", "bambu", "列印", "切片", "公仔", "外殼", "浮雕", "模型", "cnc", "雕刻", "sdf" },
        TowerTheme.call_room => new[] { "adb", "tablet", "hotline", "gmail", "calendar", "responder", "秘書", "平板", "電話", "訊息", "好友", "提醒", "行事曆", "LINE 群", "LINE 帳號", "接聽" },
        TowerTheme.trading_desk => new[] { "stock", "ticker", "backtest", "trade", "k線", "股票", "回測", "交易", "期貨", "盤後", "投資" },
        TowerTheme.media_studio => new[] { "video", "ffmpeg", "mp4", "mov", "higgsfield", "kling", "veo", "tts", "剪輯", "影片", "分鏡", "配音", "字幕", "reels", "宣傳片" },
        TowerTheme.design_studio => new[] { "design", "figma", "hig", "ui/ux", "css", "font", "logo", "設計", "配色", "品牌", "名片", "版型", "排版", "字型", "介面", "guidelines" },
        TowerTheme.legal_room => new[] { "nda", "agreement", "contract", "license agreement", "terms", "privacy", "合約", "條款", "授權書", "簽署", "分潤", "法規", "隱私權", "協議書" },
        TowerTheme.ledger_room => new[] { "invoice", "ledger", "budget", "xlsx", "csv", "accountant", "finance", "spreadsheet", "帳", "財務", "記帳", "報價", "發票", "預算", "還款", "薪資", "成本", "試算表" },
        TowerTheme.game_lab => new[] { "game", "spritekit", "unity", "godot", "sprite", "level", "poker", "holdem", "遊戲", "關卡", "角色", "手感", "玩家", "撲克", "德州", "牌桌" },
        TowerTheme.hw_lab => new[] { "bluetooth", "ble", "coreaudio", "smc", "usb", "esp32", "arduino", "firmware", "speaker", "speakers", "audio", "latency", "microphone", "volume",
                                     "display", "h.264", "藍牙", "音訊", "喇叭", "電路", "感測", "馬達", "韌體", "螢光棒", "延伸螢幕" },
        TowerTheme.marketing => new[] { "instagram", "ig", "threads", "seo", "landing", "campaign", "promo", "行銷", "貼文", "廣告", "文案", "曝光", "粉絲", "官網", "月費", "方案", "中小企業", "落地", "宣傳" },
        TowerTheme.dispatch_room => new[] { "dispatch", "ride", "flight", "fr24", "tdx", "route", "map", "派車", "派單", "接機", "航班", "行程", "司機", "車隊", "路線", "接送", "包車", "抓單" },
        TowerTheme.drafting_room => new[] { "dxf", "dwg", "floorplan", "ifc", "room", "平面圖", "建築", "室內", "水電", "給排水", "剖面", "格局", "裝潢", "建案", "拆圖", "圖檔", "工程圖", "bom" },
        _ => Array.Empty<string>(),
    };

    /// 只算半分的關鍵字（太常見：研究書房的「比較／分析／評估／索引」）
    public static string[] halfKeywords(this TowerTheme t) => t == TowerTheme.library ? new[] { "比較", "分析", "評估", "索引" } : Array.Empty<string>();

    /// 區分大小寫、照詞比對的（小寫 line 是程式用語，只有大寫 LINE 是通訊軟體）
    public static string[] caseSensitive(this TowerTheme t) => t == TowerTheme.call_room ? new[] { "LINE" } : Array.Empty<string>();

    /// 通用擺設庫（任何主題都可以挑）
    public static readonly string[] generalProps = { "plant_tall", "plant_low", "sofa", "lounge_chair", "coffee_cart", "whiteboard", "meeting_table", "bench", "wall_clock" };
    /// 識別色只准這 16 個（規範 §1.2）
    public static readonly string[] palette = { "#5B8DB8", "#4E9C8F", "#9C6B4E", "#C98B3C", "#8C7BB5", "#3F8F5A", "#B5525A", "#D08A6E",
                                                "#4A5A7A", "#A88C3E", "#7A5FA8", "#C2703A", "#C56B86", "#3E8FA8", "#6E8A6A", "#8F8B85" };

    public static HashSet<string> allowedProps(this TowerTheme t) => t.optionalProps().Concat(generalProps).ToHashSet();

    internal static int Index(TowerTheme t) => index(t);
}

// MARK: - 工作內容的特徵（本地評分，不花錢）

/// 要拿來判斷主題的原料。Agent 端從卡片（標題、自報摘要、最後一句話）與 transcript 尾端（你的指示、Edit/Write/Read 的路徑、Bash 指令第一個字）收集
public sealed record DecorInput
{
    public string Project { get; set; } = "";
    public List<string> Prompts { get; set; } = new();     // 你最近的指示（最多 3 則進提示詞）
    public List<string> Notes { get; set; } = new();       // 卡片標題、自報 summary／doing、AI 最後一句（只拿來評分，不進提示詞）
    public List<string> Paths { get; set; } = new();       // 改過／讀過的檔案路徑
    public List<string> Commands { get; set; } = new();    // Bash 指令第一個字（swift、ffmpeg…）
    public string? Readme { get; set; }                    // README 前 600 字（只有第一次）
    public DecorInput() { }
    public DecorInput(string project) { Project = project; }

    static readonly HashSet<string> fileTools = new() { "Read", "Edit", "Write", "MultiEdit", "NotebookEdit" };
    static readonly HashSet<string> skipWords = new() { "cd", "echo", "export", "sudo", "time", "env", "nohup", "then", "do", "if", "for", "true", "false", "set", "source", "." };

    /// transcript 尾端（同審核員，最後約 200KB）→ 你最近的指示、Edit/Write/Read 的路徑、Bash 指令第一個字。
    /// 只看主對話（isSidechain 不算），系統通知不算你的指示
    public static (List<string> prompts, List<string> paths, List<string> commands) extract(string tail)
    {
        List<string> prompts = new(), paths = new(), cmds = new();
        foreach (var raw in tail.Split('\n'))
        {
            if (raw.Length == 0) continue;
            JsonObject? o;
            try { o = JsonNode.Parse(raw) as JsonObject; } catch { continue; }
            if (o == null || o["isSidechain"]?.ToString() == "true" || o["message"] is not JsonObject m) continue;
            switch (o["type"]?.ToString())
            {
                case "user":
                    if (o["isMeta"]?.ToString() == "true" || o["isCompactSummary"]?.ToString() == "true") break;
                    if (m["content"] is JsonValue cv && cv.TryGetValue<string>(out var c) && c.Length > 0 && !TranscriptInfo.IsSystemMessage(c)) prompts.Add(c);
                    foreach (var p in (m["content"] as JsonArray)?.OfType<JsonObject>() ?? Enumerable.Empty<JsonObject>())
                        if (p["type"]?.ToString() == "text" && p["text"] is JsonValue tv && tv.TryGetValue<string>(out var t) && t.Length > 0 && !TranscriptInfo.IsSystemMessage(t)) prompts.Add(t);
                    break;
                case "assistant":
                    foreach (var p in (m["content"] as JsonArray)?.OfType<JsonObject>() ?? Enumerable.Empty<JsonObject>())
                    {
                        if (p["type"]?.ToString() != "tool_use") continue;
                        var name = p["name"]?.ToString() ?? ""; var inp = p["input"] as JsonObject;
                        if (fileTools.Contains(name) && (inp?["file_path"] ?? inp?["notebook_path"]) is JsonValue fv && fv.TryGetValue<string>(out var f)) paths.Add(f);
                        if (name == "Bash" && inp?["command"] is JsonValue bv && bv.TryGetValue<string>(out var cmd)) cmds.AddRange(commandWords(cmd));
                    }
                    break;
            }
        }
        return (prompts, paths, cmds);
    }

    /// README 去噪（10-20 §4.3）：拿掉徽章／圖片行（![、[![、> [!、<img、<p、<a）、程式碼區塊、HTML 註解、網址
    public static string cleanReadme(string s)
    {
        var out_ = new List<string>();
        bool inCode = false;
        foreach (var raw in s.Split('\n'))
        {
            var line = raw.Trim(' ', '\t');
            if (line.StartsWith("```")) { inCode = !inCode; continue; }
            if (inCode) continue;
            if (line.StartsWith("![") || line.StartsWith("[![") || line.StartsWith("> [!") || line.StartsWith('<')) continue;
            var l = raw;
            l = Regex.Replace(l, @"https?://\S+", "");
            l = Regex.Replace(l, @"github\.com/\S+", "");
            l = Regex.Replace(l, @"\]\([^)]*\)", "]");
            out_.Add(l);
        }
        return string.Join("\n", out_);
    }

    /// README → (標題行＋第一段, 其餘)。第一段＝標題之後第一個非空段落（到空行或 ## 為止）
    public static (string head, string rest) readmeParts(string s)
    {
        var lines = cleanReadme(s).Split('\n');
        var head = new List<string>(); int i = 0;
        while (i < lines.Length && lines[i].Trim(' ', '\t').Length == 0) i++;
        while (i < lines.Length && lines[i].StartsWith("# ")) { head.Add(lines[i][2..]); i++; }
        while (i < lines.Length && lines[i].Trim(' ', '\t').Length == 0) i++;
        while (i < lines.Length)
        {
            var l = lines[i].Trim(' ', '\t');
            if (l.Length == 0 || l.StartsWith('#')) break;
            head.Add(l); i++;
        }
        return (string.Join("\n", head), string.Join("\n", lines[Math.Min(i, lines.Length)..]));
    }

    /// 一行 shell 指令 → 每一段（&& ; | 分開）的第一個字（cd、echo、VAR=x 這類略過；路徑取最後一節）
    public static List<string> commandWords(string c)
    {
        var out_ = new List<string>();
        foreach (var seg in c.Split('&', ';', '|', '\n'))
        {
            foreach (var s in seg.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
            {
                if (s.Contains('=') || s.StartsWith('-') || s.StartsWith('(') || s.StartsWith('$') || s.StartsWith('"') || s.StartsWith('\'')) continue;
                if (skipWords.Contains(s)) break;
                var b = s.TrimEnd('/');
                var idx = b.LastIndexOf('/');
                var @base = idx >= 0 ? b[(idx + 1)..] : b;
                if (@base.Length > 0 && char.IsLetter(@base[0])) out_.Add(@base);
                break;
            }
        }
        return out_;
    }
}

public sealed record WorkSignature
{
    public Dictionary<string, int> Terms { get; set; } = new();          // 前 12 個詞＋次數
    public Dictionary<TowerTheme, int> Scores { get; set; } = new();     // 每個主題的分數（身分＋工作；提示詞、重新裝潢判斷用）
    public Dictionary<TowerTheme, int> Identity { get; set; } = new();   // 身分分數：專案名 ×2、README 標題與第一段 ×4、README 其餘 ×1（10-20 §4.3）
    public Dictionary<TowerTheme, int> Work { get; set; } = new();       // 工作分數：卡片標題／自報／transcript 路徑與指令 ×1
    public Dictionary<string, int> Extensions { get; set; } = new();     // 副檔名統計（提示詞用）
    public Dictionary<string, int> Folders { get; set; } = new();        // 資料夾名統計（提示詞用）
    public Dictionary<string, int> Commands { get; set; } = new();       // 指令統計（提示詞用）

    static readonly HashSet<string> stop = new() { "the", "and", "for", "users", "github", "repos", "sources", "src", "md", "json",
                                                   "txt", "py", "sh", "swift", "tmp", "private", "claude", "a", "to", "of", "in", "is", "it", "on", Environment.UserName.ToLowerInvariant() };

    static bool asciiAlnum(char c) => c < 128 && char.IsLetterOrDigit(c);
    static IEnumerable<string> asciiWords(string s)
    {
        int i = 0;
        while (i < s.Length)
        {
            while (i < s.Length && !asciiAlnum(s[i])) i++;
            int j = i;
            while (j < s.Length && asciiAlnum(s[j])) j++;
            if (j > i) yield return s[i..j];
            i = j;
        }
    }
    static int occurrences(string text, string k)
    {
        if (k.Length == 0) return 0;
        int n = 0;
        for (int i = text.IndexOf(k, StringComparison.Ordinal); i >= 0; i = text.IndexOf(k, i + k.Length, StringComparison.Ordinal)) n++;
        return n;
    }

    /// 一段文字對每個主題的命中分數（純英數字照詞、其他照子字串；半分詞 ×0.5；大寫 LINE 區分大小寫照詞）
    static Dictionary<TowerTheme, double> hits(string raw)
    {
        var text = raw.ToLowerInvariant();
        var count = new Dictionary<string, int>();
        foreach (var w in asciiWords(text)) count[w] = count.GetValueOrDefault(w) + 1;
        var exact = new Dictionary<string, int>();
        foreach (var w in asciiWords(raw)) exact[w] = exact.GetValueOrDefault(w) + 1;
        int n(string k0)
        {
            var k = k0.ToLowerInvariant();
            if (k.All(asciiAlnum)) return count.GetValueOrDefault(k);
            return occurrences(text, k);
        }
        var out_ = new Dictionary<TowerTheme, double>();
        foreach (var t in TowerThemes.allCases)
        {
            if (t == TowerTheme.general) continue;
            double x = 0.0;
            foreach (var k in t.keywords()) x += n(k);
            foreach (var k in t.halfKeywords()) x += n(k) * 0.5;
            foreach (var k in t.caseSensitive()) x += exact.GetValueOrDefault(k);
            if (x > 0) out_[t] = x;
        }
        return out_;
    }

    /// 專案名拆詞：DemoLine42 → Demo Line 42、In_Unison42 → In Unison 42（只用在身分分數）
    public static string splitName(string s)
    {
        var out_ = new System.Text.StringBuilder();
        char? prev = null;
        foreach (var c in s)
        {
            if (c is '_' or '-' or '.') { out_.Append(' '); prev = null; continue; }
            if (prev is { } p && ((char.IsUpper(c) && char.IsLower(p)) || (char.IsDigit(c) && char.IsLetter(p)) || (char.IsLetter(c) && char.IsDigit(p)))) out_.Append(' ');
            out_.Append(c); prev = c;
        }
        return out_.ToString();
    }

    /// 路徑的副檔名、上一層資料夾（Mac 只認 /；Windows 的 \ 也算分隔）
    static string ext(string p) { var f = p.Split('/', '\\')[^1]; int i = f.LastIndexOf('.'); return i > 0 && i < f.Length - 1 ? f[(i + 1)..] : ""; }

    public static WorkSignature make(DecorInput inp)
    {
        var s = new WorkSignature();
        foreach (var p in inp.Paths)
        {
            var e = ext(p).ToLowerInvariant();
            if (e.Length > 0) s.Extensions[e] = s.Extensions.GetValueOrDefault(e) + 1;
            var comps = p.Split('/', '\\');
            var dirs = comps.Take(comps.Length - 1).Where(x => x.Length > 0).TakeLast(2);
            foreach (var comp in dirs) if (comp.Length > 1 && !comp.StartsWith('.')) s.Folders[comp] = s.Folders.GetValueOrDefault(comp) + 1;
        }
        foreach (var c in inp.Commands) if (c.Length > 0) { var k = c.ToLowerInvariant(); s.Commands[k] = s.Commands.GetValueOrDefault(k) + 1; }
        // 身分：專案名（拆詞、大小寫照原樣）×2＋README 標題與第一段 ×4＋README 其餘 ×1
        var (head, rest) = DecorInput.readmeParts(inp.Readme ?? "");
        var id = new Dictionary<TowerTheme, double>();
        foreach (var (t, v) in hits(splitName(inp.Project))) id[t] = id.GetValueOrDefault(t) + v * 2;
        foreach (var (t, v) in hits(head)) id[t] = id.GetValueOrDefault(t) + v * 4;
        foreach (var (t, v) in hits(rest)) id[t] = id.GetValueOrDefault(t) + v;
        // 工作：卡片、你的指示、路徑、指令
        var wk = hits(string.Join("\n", inp.Prompts.Concat(inp.Notes).Concat(inp.Paths).Concat(inp.Commands)));
        // 研究書房：最近碰的檔案 .md 佔一半以上（規範 §2.1 #3）
        int md = inp.Paths.Count(x => x.ToLowerInvariant().EndsWith(".md"));
        if (md >= 3 && md * 2 >= inp.Paths.Count) wk[TowerTheme.library] = wk.GetValueOrDefault(TowerTheme.library) + md / 2;
        static Dictionary<TowerTheme, int> round(Dictionary<TowerTheme, double> m) =>
            m.Select(kv => (kv.Key, r: (int)Math.Round(kv.Value, MidpointRounding.AwayFromZero))).Where(x => x.r > 0).ToDictionary(x => x.Key, x => x.r);
        s.Identity = round(id); s.Work = round(wk);
        s.Scores = new Dictionary<TowerTheme, int>(s.Identity);
        foreach (var (k, v) in s.Work) s.Scores[k] = s.Scores.GetValueOrDefault(k) + v;
        var text = string.Join("\n", new[] { inp.Project }.Concat(inp.Prompts).Concat(inp.Notes).Concat(inp.Paths).Concat(inp.Commands).Append(DecorInput.cleanReadme(inp.Readme ?? ""))).ToLowerInvariant();
        var count = new Dictionary<string, int>();
        foreach (var w in asciiWords(text)) count[w] = count.GetValueOrDefault(w) + 1;
        var ranked = count.Where(kv => kv.Key.Length >= 2 && !stop.Contains(kv.Key) && !kv.Key.All(char.IsDigit))
                          .OrderByDescending(kv => kv.Value).ThenBy(kv => kv.Key, StringComparer.Ordinal).Take(12);
        s.Terms = ranked.ToDictionary(kv => kv.Key, kv => kv.Value);
        return s;
    }

    static (TowerTheme theme, int score)? top(Dictionary<TowerTheme, int> m)
    {
        (TowerTheme, int)? best = null;
        foreach (var t in TowerThemes.allCases)
        {
            if (!m.TryGetValue(t, out var v)) continue;
            if (best == null || v > best.Value.Item2) best = (t, v);     // 同分取 allCases 裡前面的
        }
        return best;
    }

    /// 身分分數前 n 名（分數 > 0）
    public List<TowerTheme> identityTop(int n) =>
        Identity.OrderByDescending(kv => kv.Value).ThenBy(kv => TowerThemes.Index(kv.Key)).Take(n).Select(kv => kv.Key).ToList();

    /// 主題（10-20 §4.3）：身分最高者；工作分數要換掉它，必須 ≥ 身分最高分 × 2 且命中 ≥ 5。沒有任何身分線索 ⇒ 看工作；全部 0 ＝ general
    public (TowerTheme theme, int score) best
    {
        get
        {
            // 只有合計分數（舊格式、手組的 signature）：照合計最高
            if (Identity.Count == 0 && Work.Count == 0) return top(Scores) ?? (TowerTheme.general, 0);
            var w = top(Work);
            if (top(Identity) is not { } id) return w ?? (TowerTheme.general, 0);
            if (w is { } ww && ww.theme != id.theme && ww.score >= 5 && ww.score >= id.score * 2) return ww;
            return id;
        }
    }

    public Dictionary<string, int> scoreStrings => Scores.ToDictionary(kv => kv.Key.rawValue(), kv => kv.Value);

    /// 加權 Jaccard：Σmin / Σmax（兩邊都空＝1，完全一樣）
    public static double jaccard(Dictionary<string, int> a, Dictionary<string, int> b)
    {
        var keys = a.Keys.Union(b.Keys).ToList();
        if (keys.Count == 0) return 1;
        int lo = 0, hi = 0;
        foreach (var k in keys) { int x = a.GetValueOrDefault(k), y = b.GetValueOrDefault(k); lo += Math.Min(x, y); hi += Math.Max(x, y); }
        return hi == 0 ? 1 : (double)lo / hi;
    }
}

// MARK: - 快取（board/themes/<專案>.json，格式照規範 §5.3）

public sealed record FloorDecor
{
    public TowerTheme Theme { get; set; }
    public string AccentColor { get; set; } = "";
    public List<string> Props { get; set; } = new();
    public string Reason { get; set; } = "";
    public string Source { get; set; } = "";        // ai｜local
    public string? Model { get; set; }
    public double? CostUSD { get; set; }
    public DateTime DecidedAt { get; set; }
    public Dictionary<string, int> Signature { get; set; } = new();
    public Dictionary<string, int> Scores { get; set; } = new();
    public string? FloorNo { get; set; }
    public double? Seconds { get; set; }            // AI 花了幾秒（除錯用）

    public FloorDecor() { }
    public FloorDecor(TowerTheme theme, string accentColor, List<string> props, string reason, string source, DateTime decidedAt, string? model = null,
                      double? costUSD = null, Dictionary<string, int>? signature = null, Dictionary<string, int>? scores = null, string? floorNo = null, double? seconds = null)
    {
        Theme = theme; AccentColor = accentColor; Props = props; Reason = reason; Source = source; Model = model; CostUSD = costUSD;
        DecidedAt = decidedAt; Signature = signature ?? new(); Scores = scores ?? new(); FloorNo = floorNo; Seconds = seconds;
    }

    /// 本地評分的結果：分數最高的主題＋預設識別色＋可選件前 2 件
    public static FloorDecor local(WorkSignature sig, DateTime now, string reason = "依最近工作的關鍵字判斷")
    {
        var t = sig.best.theme;
        return new FloorDecor(t, t.accent(), t.optionalProps().Take(2).ToList(), reason, "local", now, signature: sig.Terms, scores: sig.scoreStrings);
    }

    static readonly JsonSerializerOptions Opt = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true,
                                                        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };
    public static FloorDecor? decode(string d) { try { return JsonSerializer.Deserialize<FloorDecor>(d, Opt); } catch { return null; } }
    public string encoded() => JsonSerializer.Serialize(this, Opt);
}

// MARK: - 提示詞與解析

public static class DecorPrompt
{
    /// 主題庫那段固定（可快取的常數）
    public static readonly string library = string.Join("\n", TowerThemes.allCases.Select(t => $"{t.rawValue()}｜{t.title()}｜{t.blurb()}｜{string.Join(", ", t.optionalProps())}"));

    public const string system = "你是一棟 AI 科技大樓的室內設計師。只輸出一個 JSON 物件，不要任何其他文字。";

    public static string make(DecorInput inp, WorkSignature signature, TowerTheme? current)
    {
        static string top(Dictionary<string, int> m, int n, string prefix = "")
        {
            var s = string.Join("、", m.OrderByDescending(kv => kv.Value).ThenBy(kv => kv.Key, StringComparer.Ordinal).Take(n).Select(kv => $"{prefix}{kv.Key} ×{kv.Value}"));
            return s.Length == 0 ? "（無）" : s;
        }
        var prompts = string.Join("\n", inp.Prompts.TakeLast(3).Select(p => "  - " + Board.Prefix(Board.Plain(p), 160)));
        var lines = new List<string>
        {
            "你是一棟 AI 科技大樓的室內設計師。每層樓是一個軟體專案的部門。",
            "請依照這個專案「最近在做的事」，從主題庫挑一個最貼切的樓層主題、一個識別色、2–3 件專屬擺設。",
            "風格是克制的現代辦公室：全樓地板一致、家具中性色，識別色只會用在門牌色條和一件主題家具上。",
            "",
            $"【專案】{inp.Project}",
            $"【目前主題】{(current?.rawValue() ?? "無")}",
            "【最近工作的線索】",
            "- 你（使用者）最近的指示：" + (prompts.Length == 0 ? "（無）" : "\n" + prompts),
            "- 改過／讀過的檔案類型：" + top(signature.Extensions, 6, "."),
            "- 常用指令：" + top(signature.Commands, 6),
            "- 資料夾關鍵詞：" + top(signature.Folders, 6),
            "- 其他線索（卡片標題、進度摘要）：" + (inp.Notes.Count == 0 ? "（無）" : string.Join("／", inp.Notes.Take(4).Select(x => Board.Prefix(Board.Plain(x), 120)))),
        };
        if (inp.Readme is { Length: > 0 } r) lines.Add("- README 摘要：" + Board.Prefix(r, 600).Replace("\n", " "));
        lines.AddRange(new[]
        {
            "",
            "【主題庫】（只能從這裡選 theme；格式：id｜中文名｜適用｜可選擺設）",
            library,
            "",
            "【通用擺設】" + string.Join(", ", TowerThemes.generalProps),
            "【識別色】只能從這 16 個挑：" + string.Join(", ", TowerThemes.palette),
            "",
            "只輸出一個 JSON 物件，不要任何其他文字：",
            """{"theme": "...", "accentColor": "#RRGGBB", "props": ["...", "..."], "reason": "..."}""",
            "規則：props 2–3 個、不重複、只能從該主題的可選擺設或通用擺設裡挑；reason 用繁體中文、30 字以內，說明為什麼。",
        });
        return string.Join("\n", lines);
    }

    /// 解析 AI 的回答＋驗證（規範 §5.3）。theme 不認得 ⇒ nil（呼叫端改用本地結果）；識別色不在 16 色裡 ⇒ 主題預設色；
    /// props 只留合法的、去重、最多 3 件，不到 2 件用該主題可選件補；容忍 ```json 圍欄
    public static FloorDecor? parse(string text, WorkSignature signature, string model, double? cost, DateTime now)
    {
        int s = text.IndexOf('{'), e = text.LastIndexOf('}');
        if (s < 0 || e < 0 || s >= e) return null;
        JsonObject? o;
        try { o = JsonNode.Parse(text[s..(e + 1)]) as JsonObject; } catch { return null; }
        if (o?["theme"] is not JsonValue tv || !tv.TryGetValue<string>(out var ts) || TowerThemes.from(ts.Trim()) is not { } t) return null;
        // 10-20 §4.3：識別色一律用主題預設色（AI 自己挑的色跟主題色不一致，同一主題兩種色，識別色就沒意義了）
        var accent = t.accent();
        var props = new List<string>();
        foreach (var p in (o["props"] as JsonArray)?.Select(x => x is JsonValue v && v.TryGetValue<string>(out var str) ? str : null).OfType<string>() ?? Enumerable.Empty<string>())
            if (t.allowedProps().Contains(p) && !props.Contains(p) && props.Count < 3) props.Add(p);
        foreach (var p in t.optionalProps().Concat(TowerThemes.generalProps))
            if (props.Count < 2 && !props.Contains(p)) props.Add(p);
        var reason = Board.Prefix(((o["reason"] as JsonValue)?.TryGetValue<string>(out var rs) == true ? rs : "").Trim(), 40);
        return new FloorDecor(t, accent, props, reason, "ai", now, model: model, costUSD: cost, signature: signature.Terms, scores: signature.scoreStrings);
    }
}

// MARK: - 什麼時候問 AI（規範 §5.4）

/// 呼叫紀錄（board/decor_ledger.json）：滾動 24 小時的次數、成本、失敗退避
public sealed record DecorLedger
{
    public sealed record Call
    {
        public DateTime At { get; set; }
        public string Project { get; set; } = "";       // 小寫
        public double? Cost { get; set; }
        public bool Ok { get; set; }
        public double? Seconds { get; set; }
        public Call() { }
        public Call(DateTime at, string project, double? cost, bool ok, double? seconds = null) { At = at; Project = project.ToLowerInvariant(); Cost = cost; Ok = ok; Seconds = seconds; }
    }
    public List<Call> Calls { get; set; } = new();

    public List<Call> recent(DateTime now, TimeSpan? within = null) => Calls.Where(c => now - c.At < (within ?? TimeSpan.FromDays(1))).ToList();
    /// 只留 2 天內的（檔案不會一直長）
    public void prune(DateTime now) => Calls = Calls.Where(c => now - c.At < TimeSpan.FromDays(2)).ToList();

    static readonly JsonSerializerOptions Opt = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true };
    public static DecorLedger? decode(string d) { try { return JsonSerializer.Deserialize<DecorLedger>(d, Opt); } catch { return null; } }
    public string encoded() => JsonSerializer.Serialize(this, Opt);
}

public sealed record DecorLimits
{
    public TimeSpan PerProject { get; set; } = TimeSpan.FromHours(6);     // 同專案兩次問 AI／換裝至少間隔
    public int PerDay { get; set; } = 8;                                  // 全部專案合計滾動 24 小時
    public double CostPerDay { get; set; } = 0.10;                        // US$／滾動 24 小時
    public double AssumedCost { get; set; } = 0.01;                       // 沒回傳成本的那次以這個計
    public TimeSpan FailBackoff { get; set; } = TimeSpan.FromHours(1);    // 失敗後多久不再試（同專案）
    public int MinHits { get; set; } = 3;                                 // 新主題至少命中幾次
    public double Ratio { get; set; } = 2.0;                              // 新主題分數 ≥ 舊主題 × 這個
    public double Jaccard { get; set; } = 0.5;                            // 新舊 signature 相似度 < 這個才算「真的變了」
}

/// keep(原因)＝不動；local＝第一次、AI 不能問 ⇒ 先用本地評分；ask(原因)＝問 AI
public sealed record DecorDecision(string Case, string? Why = null)
{
    public static DecorDecision keep(string why) => new("keep", why);
    public static readonly DecorDecision local = new("local");
    public static DecorDecision ask(string why) => new("ask", why);
    public bool isAsk => Case == "ask";
}

public static class DecorPolicy
{
    /// 現在能不能再問 AI（頻率／成本／失敗退避／同時一個）；不行回傳原因
    public static string? blocked(string project, DecorLedger ledger, bool running, bool enabled, bool force, DecorLimits? limits, DateTime now)
    {
        var l = limits ?? new DecorLimits();
        if (!enabled) return "AI 裝潢關著";
        if (running) return "已經有一個在跑";
        var k = project.ToLowerInvariant();
        var day = ledger.recent(now);
        if (day.Count >= l.PerDay) return $"24 小時內已經問了 {day.Count} 次";
        var cost = day.Sum(c => c.Cost ?? l.AssumedCost);
        if (cost >= l.CostPerDay) return string.Format(CultureInfo.InvariantCulture, "24 小時成本已到 US${0:F3}", cost);
        var mine = ledger.Calls.Where(c => c.Project == k).ToList();
        if (mine.LastOrDefault(c => !c.Ok) is { } f && now - f.At < l.FailBackoff && mine.LastOrDefault()?.Ok != true) return "上次失敗，1 小時內不再試";
        if (!force && mine.LastOrDefault(c => c.Ok) is { } ok && now - ok.At < l.PerProject) return "同專案 6 小時內問過";
        return null;
    }

    /// 要不要換裝、要不要問 AI。`turnEnded`＝這次刷新有 session 一輪工作結束；`force`＝你按了「重新裝潢」
    public static DecorDecision decide(FloorDecor? cached, WorkSignature signature, bool turnEnded, string? blocked, bool force, DecorLimits? limits, DateTime now)
    {
        var l = limits ?? new DecorLimits();
        if (force) return blocked != null ? DecorDecision.keep(blocked) : DecorDecision.ask("重新裝潢");
        if (cached is not { } c) return blocked == null ? DecorDecision.ask("第一次") : DecorDecision.local;
        if (c.Source != "ai") return blocked != null ? DecorDecision.keep(blocked) : DecorDecision.ask("本地結果請 AI 覆核");
        if (!turnEnded) return DecorDecision.keep("不是一輪結束");
        if (now - c.DecidedAt < l.PerProject) return DecorDecision.keep("換裝後 6 小時內不再換");
        var (best, score) = signature.best;
        if (best == c.Theme) return DecorDecision.keep("主題沒變");
        int old = signature.Scores.GetValueOrDefault(c.Theme);
        if (!(score >= l.MinHits && score >= old * l.Ratio)) return DecorDecision.keep("差距不夠大");
        double j = WorkSignature.jaccard(signature.Terms, c.Signature);
        if (!(j < l.Jaccard)) return DecorDecision.keep(string.Format(CultureInfo.InvariantCulture, "工作內容沒有明顯變化（{0:F2}）", j));
        return blocked != null ? DecorDecision.keep(blocked) : DecorDecision.ask($"工作內容變了：{c.Theme.rawValue()} → {best.rawValue()}");
    }

    /// AI 只做微調（10-20 §4.3）：AI 的主題只有在「本地身分分數前 2 名之內」或「本地身分最高分 < 3（看不出身分）」時才採用；
    /// 否則保留本地身分判斷的主題，只收 AI 挑的擺設（不屬於這個主題的換成主題預設件）。識別色一律鎖主題預設色。
    /// 本地結果（source ≠ ai）也走同一條：舊版評分判錯、而身分很明確的，換成身分主題。
    public static FloorDecor reconcile(FloorDecor d, WorkSignature identity)
    {
        var out_ = d with { Props = d.Props.ToList() };
        var top = identity.identityTop(2);
        int topScore = top.Count > 0 ? identity.Identity.GetValueOrDefault(top[0]) : 0;
        if (topScore >= 3 && !top.Contains(d.Theme))
        {
            var t = identity.best.theme;
            out_.Theme = t;
            var props = d.Props.Where(p => t.allowedProps().Contains(p)).ToList();
            foreach (var p in t.optionalProps()) if (props.Count < 2 && !props.Contains(p)) props.Add(p);
            out_.Props = props.Take(3).ToList();
            out_.Reason = d.Source == "ai" ? $"AI 建議{d.Theme.title()}，依專案身分改成{t.title()}" : "依專案身分判斷";
        }
        out_.AccentColor = out_.Theme.accent();
        return out_;
    }
}

// MARK: - 主題選擇器（快取＋節流＋背景呼叫）

/// 每個專案的樓層主題。讀快取、決定要不要問 AI、在背景問、寫回快取。runner 可注入（測試一律假的）。
/// `dir` 底下：themes/<專案>.json、decor_ledger.json
public sealed class ThemePicker
{
    /// prompt → (結束碼, stdout, stderr)。正式版跑 claude -p --output-format json，stdout 是 {"result":…, "total_cost_usd":…}
    public delegate (int code, string @out, string err) Runner(string prompt);

    public string Dir { get; }
    public string Model { get; }
    public DecorLimits Limits { get; }
    readonly Runner runner;
    readonly object gate = new();
    readonly Dictionary<string, FloorDecor> cache = new();      // 小寫 → 主題
    bool loaded;
    DecorLedger ledger = new();
    string? running;                                             // 正在問的專案（小寫）
    readonly Func<DateTime> clock;
    /// 背景工作（Mac：DispatchQueue；這裡一次只排一個 Task，串在前一個後面）
    Task queue = Task.CompletedTask;

    public ThemePicker(string dir, Runner runner, string model = "haiku", DecorLimits? limits = null, Func<DateTime>? clock = null)
    {
        Dir = dir; Model = model; Limits = limits ?? new DecorLimits(); this.clock = clock ?? (() => DateTime.UtcNow); this.runner = runner;
    }

    string themesDir => Path.Combine(Dir, "themes");
    string ledgerPath => Path.Combine(Dir, "decor_ledger.json");
    /// 專案名當檔名：/ 與 : 換掉（Windows 另外把 \ * ? " < > | 也換掉：檔名不准有）
    public static string fileName(string project)
    {
        var s = project.Replace("/", "_").Replace(":", "_");
        foreach (var c in new[] { '\\', '*', '?', '"', '<', '>', '|' }) s = s.Replace(c, '_');
        return s + ".json";
    }

    void loadIfNeeded()
    {
        if (loaded) return;
        loaded = true;
        try
        {
            if (Directory.Exists(themesDir))
                foreach (var f in Directory.EnumerateFiles(themesDir, "*.json"))
                    if (FloorDecor.decode(File.ReadAllText(f)) is { } v) cache[Path.GetFileNameWithoutExtension(f).ToLowerInvariant()] = v;
            if (File.Exists(ledgerPath) && DecorLedger.decode(File.ReadAllText(ledgerPath)) is { } l) ledger = l;
        }
        catch { }
    }

    /// 全部快取（小寫專案名 → 主題）
    public Dictionary<string, FloorDecor> all() { lock (gate) { loadIfNeeded(); return new(cache); } }
    public FloorDecor? cached(string project) => all().GetValueOrDefault(project.ToLowerInvariant());
    public string? runningProject { get { lock (gate) return running; } }
    public DecorLedger ledgerSnapshot { get { lock (gate) { loadIfNeeded(); return ledger with { Calls = ledger.Calls.ToList() }; } } }
    /// 等背景工作做完（測試用）
    public Task idle { get { lock (gate) return queue; } }

    void save(string project, FloorDecor v)
    {
        try
        {
            Directory.CreateDirectory(themesDir);
            var path = Path.Combine(themesDir, fileName(project));
            var tmp = path + $".{Environment.ProcessId}.tmp";
            File.WriteAllText(tmp, v.encoded());
            File.Move(tmp, path, overwrite: true);
        }
        catch { }
    }
    void saveLedger()
    {
        try
        {
            Directory.CreateDirectory(Dir);
            string text; lock (gate) text = ledger.encoded();
            var tmp = ledgerPath + $".{Environment.ProcessId}.tmp";
            File.WriteAllText(tmp, text);
            File.Move(tmp, ledgerPath, overwrite: true);
        }
        catch { }
    }

    void enqueue(Action a) { lock (gate) queue = queue.ContinueWith(_ => { try { a(); } catch { } }, TaskScheduler.Default); }

    /// 直接寫一筆（正式 agent 用專案身分校正過的結果；不呼叫 AI）
    public void store(string project, FloorDecor v)
    {
        lock (gate) { loadIfNeeded(); cache[project.ToLowerInvariant()] = v; }
        save(project, v);
    }

    /// 便宜的前置檢查（每次刷新都可以叫）：這個專案這次有沒有可能要動？沒有就不用去收集 transcript。
    public bool mayChange(string project, bool turnEnded, bool enabled, bool force = false)
    {
        lock (gate)
        {
            loadIfNeeded();
            var now = clock();
            if (!cache.TryGetValue(project.ToLowerInvariant(), out var c)) return true;                 // 第一次：至少要先放本地結果
            var blocked = DecorPolicy.blocked(project, ledger, running != null, enabled, force, Limits, now);
            if (force) return blocked == null;
            if (c.Source != "ai") return blocked == null;
            return turnEnded && blocked == null && now - c.DecidedAt >= Limits.PerProject;
        }
    }

    /// 決定並（必要時）在背景問 AI。`input` 在背景才叫（讀 transcript 不卡 UI 執行緒）。
    /// `changed` 在背景被叫：本地結果先寫好時叫一次、AI 回來（成功）再叫一次。回傳是否排了工作
    public bool consider(string project, bool turnEnded, bool enabled, Func<DecorInput> input, bool force = false,
                         Action<FloorDecor>? changed = null, Action<DecorDecision>? finished = null)
    {
        if (!mayChange(project, turnEnded, enabled, force)) return false;
        var key = project.ToLowerInvariant();
        lock (gate)
        {
            // 真正要問之前才佔位（同時只跑一個）；先佔住，決定不問再放掉
            if (running != null)
            {
                // 已有別的在跑：第一次的專案還是要先有本地結果
                if (!cache.ContainsKey(key))
                {
                    enqueue(() =>
                    {
                        var sig = WorkSignature.make(input());
                        var v = FloorDecor.local(sig, clock());
                        bool fresh;
                        lock (gate) { fresh = !cache.ContainsKey(key); if (fresh) cache[key] = v; }
                        if (fresh) { save(project, v); changed?.Invoke(v); }
                        finished?.Invoke(DecorDecision.local);
                    });
                    return true;
                }
                return false;
            }
            running = key;
        }
        enqueue(() =>
        {
            var inp = input();
            var sig = WorkSignature.make(inp);
            var now = clock();
            FloorDecor? cur; string? blocked;
            lock (gate)
            {
                cur = cache.GetValueOrDefault(key);
                blocked = DecorPolicy.blocked(project, ledger, false, enabled, force, Limits, now);
            }
            var d = DecorPolicy.decide(cur, sig, turnEnded, blocked, force, Limits, now);
            // 第一次：不管等一下問不問 AI，先放本地結果（畫面不用等）
            if (cur == null)
            {
                var v0 = FloorDecor.local(sig, now);
                lock (gate) cache[key] = v0;
                save(project, v0); changed?.Invoke(v0);
            }
            if (!d.isAsk)
            {
                lock (gate) running = null;
                finished?.Invoke(d); return;
            }
            var prompt = DecorPrompt.make(inp, sig, cur?.Source == "ai" ? cur.Theme : null);
            var t0 = DateTime.UtcNow;
            var r = runner(prompt);
            var secs = (DateTime.UtcNow - t0).TotalSeconds;
            JsonObject? o = null;
            try { o = JsonNode.Parse(r.@out) as JsonObject; } catch { }
            var text = o?["result"] is JsonValue rv && rv.TryGetValue<string>(out var rs) ? rs : r.@out;
            double? cost = o?["total_cost_usd"] is JsonValue cv && cv.TryGetValue<double>(out var cd) ? cd : null;
            bool isErr = o?["is_error"] is JsonValue ev && ev.TryGetValue<bool>(out var eb) && eb;
            // AI 只做微調：主題不在本地身分前 2 名就不採用（只收擺設）、識別色鎖主題預設色
            var v = r.code == 0 && !isErr && DecorPrompt.parse(text, sig, Model, cost, clock()) is { } p ? DecorPolicy.reconcile(p, sig) : null;
            var rsecs = Math.Round(secs * 10, MidpointRounding.AwayFromZero) / 10;
            if (v != null) v.Seconds = rsecs;
            lock (gate)
            {
                ledger.Calls.Add(new DecorLedger.Call(now, key, cost, v != null, rsecs));
                ledger.prune(now);
                if (v != null) cache[key] = v;
                running = null;
            }
            saveLedger();
            if (v != null) { save(project, v); changed?.Invoke(v); }
            finished?.Invoke(v == null ? DecorDecision.keep($"AI 失敗（{r.code}）：{Board.Prefix(r.err.Length == 0 ? text : r.err, 120)}") : d);
        });
        return true;
    }
}
