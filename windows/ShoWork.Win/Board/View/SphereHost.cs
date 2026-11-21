using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace ShoWork;

/// 戰情中心第三個檢視「球體」：WebView2 ＋ Board\Web\sphere.html（three.js 用 vendor 那份，離線可用）。Mac 版 SphereWebScene.swift（SphereWebHost）的移植。
///   這裡 → 網頁：ExecuteScriptAsync 呼叫 window.karaUpdate(資料)、karaToast(一句話)、karaVoice("start"|"word"|"end")、karaPrefs({mini, voice, voices})、
///               karaHeard(text, final)、karaSessionInfo(obj)
///   網頁 → 這裡：window.chrome.webview.postMessage({action, …})（sphere.html 的 winHost）
///     自己處理：ready、speak、stopSpeaking、setVoice、listen、mini
///     交給 BoardForm（ActionReceived；要卡片資料）：focus、answer、permit、captain、ask、sessionInfo、timeline、openBoard
/// 語音：Windows 內建 SAPI 的中文合成語音（COM SAPI.SpVoice，不另裝套件）；沒有中文語音就不出聲，照樣回 karaVoice("end")，網頁不會卡住。
/// 按住講話：Windows 版還沒做（回 karaHeard("", true)＋說明）。
/// ⚠ 不准用使用者本人的聲音：只列系統已安裝的合成語音，不錄音、不存音檔。
/// 測試模式（--board-window／--board-demo）：不出聲、不碰麥克風（照 Mac 假裝聽到一句）；回答、放行、交給隊長由 BoardForm 擋。
sealed class SphereHost : IDisposable
{
    public const string HostName = "sphere.showork42.invalid";

    readonly WebView2 view = new() { Dock = DockStyle.Fill, DefaultBackgroundColor = Color.FromArgb(0x05, 0x05, 0x0A) };
    readonly bool testMode;
    readonly SphereVoice voice;
    string? latest, sent;
    bool ready, started, disposed;
    readonly List<System.Windows.Forms.Timer> fakes = new();

    public Control View => view;
    public bool Failed { get; private set; }
    public bool Ready => ready && !Failed && !disposed;
    /// 要卡片資料的動作（{action, …} 整個物件；UI 執行緒）
    public event Action<JsonElement>? ActionReceived;
    /// 不能用了（原因一行），BoardForm 收到就退回卡片
    public event Action<string>? Broken;

    public SphereHost(bool testMode)
    {
        this.testMode = testMode;
        voice = new SphereVoice(ev => Voice(ev));
    }

    public async void Start()
    {
        if (started || disposed) return;
        started = true;
        try
        {
            var folder = OfficeHost.WebFolder() is { } f && File.Exists(Path.Combine(f, "sphere.html")) ? f
                       : throw new FileNotFoundException("sphere.html 不在 Web\\ 也不在內嵌資源");
            var env = await CoreWebView2Environment.CreateAsync(null, Path.Combine(Wire.SupportDir, "WebView2"));
            if (disposed) return;
            await view.EnsureCoreWebView2Async(env);
            if (disposed) return;
            var core = view.CoreWebView2;
            var s = core.Settings;
            s.AreDevToolsEnabled = Environment.GetEnvironmentVariable("SHOWORK_OFFICE_DEVTOOLS") is "1";
            s.AreDefaultContextMenusEnabled = false;
            s.IsStatusBarEnabled = false;
            s.IsZoomControlEnabled = false;
            s.AreBrowserAcceleratorKeysEnabled = false;
            s.IsGeneralAutofillEnabled = false;
            s.IsPasswordAutosaveEnabled = false;
            core.SetVirtualHostNameToFolderMapping(HostName, folder, CoreWebView2HostResourceAccessKind.DenyCors);
            core.NavigationStarting += (_, e) => { if (!e.Uri.StartsWith($"https://{HostName}/", StringComparison.OrdinalIgnoreCase)) e.Cancel = true; };
            core.NewWindowRequested += (_, e) => e.Handled = true;
            // 頁面沒用到麥克風（按住講話 Windows 版還沒做）：權限一律拒絕，不跳詢問
            core.PermissionRequested += (_, e) => e.State = CoreWebView2PermissionState.Deny;
            core.WebMessageReceived += OnMessage;
            core.ProcessFailed += (_, e) => Fail($"WebView2 process failed: {e.ProcessFailedKind}");
            core.NavigationCompleted += (_, e) =>
            {
                if (!e.IsSuccess && !ready && e.WebErrorStatus != CoreWebView2WebErrorStatus.OperationCanceled) Fail($"sphere.html 載入失敗：{e.WebErrorStatus}");
            };
            Log.Note($"SPHERE start runtime={OfficeHost.RuntimeVersion} folder={folder} test={testMode}");
            core.Navigate($"https://{HostName}/sphere.html");
        }
        catch (Exception x) { Fail($"WebView2 init failed: {x.GetType().Name} {x.Message}"); }
    }

    void Fail(string why)
    {
        if (Failed || disposed) return;
        Failed = true;
        Log.Note("SPHERE " + why);
        Broken?.Invoke(why);
    }

    // MARK: 網頁 → 這裡

    void OnMessage(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        try
        {
            using var doc = JsonDocument.Parse(e.WebMessageAsJson);
            var m = doc.RootElement;
            if (m.ValueKind != JsonValueKind.Object) return;
            var a = Str(m, "action");
            switch (a)
            {
                case "ready":
                    ready = true;
                    sent = null;
                    Flush();
                    PushPrefs();
                    return;
                case "speak":
                    Speak(Str(m, "text") ?? "");
                    return;
                case "stopSpeaking":
                    voice.Stop();
                    return;
                case "setVoice":
                {
                    // 選單選了就存起來、馬上試聽一句（只接受系統已安裝的合成語音）
                    if (Str(m, "id") is not { } id || !voice.All().Any(v => v.Id == id)) return;
                    voice.Selected = id;
                    PushPrefs();
                    Speak(Str(m, "sample") ?? "你好，我是球體助理，之後就用這個聲音播報。");
                    return;
                }
                case "listen":
                    if (m.TryGetProperty("on", out var on) && on.ValueKind == JsonValueKind.True) Listen();
                    return;
                case "mini":
                    Toast("Windows 版還沒有桌面常駐小球。");
                    PushPrefs();
                    return;
                case null:
                    return;
                default:
                    ActionReceived?.Invoke(m.Clone());
                    return;
            }
        }
        catch (Exception x) { Log.Note($"SPHERE bad message: {x.Message}"); }
    }

    static string? Str(JsonElement m, string k) => m.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    // MARK: 語音

    void Speak(string text)
    {
        var t = text.Trim();
        if (t.Length == 0) { Voice("end"); return; }
        if (testMode)
        {
            // 測試不出聲：照字數估時間，假裝唸完
            Voice("start");
            After(Math.Min(8000, (int)(180 * t.Length)), () => Voice("end"));
            return;
        }
        if (voice.Speak(Board.Prefix(t, 300)) is { } why)
        {
            Voice("end");
            if (!toldNoVoice) { toldNoVoice = true; Toast(why); }
        }
    }
    bool toldNoVoice;

    /// 按住球講話：Windows 版還沒做（Mac 是本機即時辨識）。測試模式照 Mac 假裝聽到一句、不碰麥克風
    void Listen()
    {
        if (testMode)
        {
            var words = new[] { "幫我", "幫我看一下", "幫我看一下 Alex", "幫我看一下 Alex 的進度" };
            for (int i = 0; i < words.Length; i++)
            {
                var (w, last) = (words[i], i == words.Length - 1);
                After(400 * (i + 1), () => Call("window.karaHeard", w, last));
            }
            return;
        }
        Call("window.karaHeard", "", true);
        Toast("Windows 版還不支援按住講話。");
    }

    void PushPrefs()
    {
        var vs = voice.All();
        var o = new JsonObject { ["mini"] = false, ["voice"] = voice.Selected };
        // 沒有中文語音就不送清單（網頁收到空陣列會顯示一個空的選單）
        if (vs.Count > 0)
            o["voices"] = new JsonArray(vs.Select(v => (JsonNode?)new JsonObject { ["id"] = v.Id, ["name"] = v.Name, ["group"] = v.Group }).ToArray());
        Call("window.karaPrefs", o);
    }

    void Voice(string ev) => Call("window.karaVoice", ev);

    void After(int ms, Action a)
    {
        var t = new System.Windows.Forms.Timer { Interval = Math.Max(1, ms) };
        fakes.Add(t);
        t.Tick += (_, _) => { t.Dispose(); fakes.Remove(t); if (!disposed) a(); };
        t.Start();
    }

    // MARK: 這裡 → 網頁

    /// 結果回網頁當一句播報
    public void Toast(string text) => Call("window.karaToast", text);

    /// 點衛星展開的小卡
    public void SessionInfo(JsonObject info) => Call("window.karaSessionInfo", info);

    /// 呼叫網頁上的 window.kara*（函式不在就略過）；參數一律 JSON
    public void Call(string fn, params JsonNode?[] args)
    {
        if (!Ready || view.CoreWebView2 == null) return;
        var a = string.Join(",", args.Select(x => x?.ToJsonString() ?? "null"));
        try { _ = view.CoreWebView2.ExecuteScriptAsync($"{fn} && {fn}({a})"); }
        catch (Exception x) { Log.Note($"SPHERE call {fn} failed: {x.Message}"); }
    }

    /// 推資料（內容沒變就不推）
    public void Push(JsonObject o)
    {
        latest = o.ToJsonString();
        Flush();
    }

    void Flush()
    {
        if (!Ready || latest == null || latest == sent || view.CoreWebView2 == null) return;
        try { _ = view.CoreWebView2.ExecuteScriptAsync($"window.karaUpdate && window.karaUpdate({latest})"); sent = latest; }
        catch (Exception x) { Fail($"push failed: {x.Message}"); }
    }

    /// 切走（看不到）就停止說話
    public void Hidden() => voice.Stop();

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        foreach (var t in fakes.ToList()) t.Dispose();
        fakes.Clear();
        voice.Dispose();
        try { view.Dispose(); } catch { }
    }
}

/// Windows 內建的中文合成語音（SAPI 5，COM「SAPI.SpVoice」用 late binding 呼叫，不另裝 System.Speech 套件；
/// 也不用 CultureInfo：這個程式開了 InvariantGlobalization，new CultureInfo("zh-TW") 會丟例外）。
/// 只看得到 SAPI 的桌面語音（例如中文（台灣）語言套件的 Microsoft Hanhan／Yating／Zhiwei Desktop，看安裝了什麼）。
/// 進度用輪詢：每 60 ms 看 Status.RunningState（2＝在唸、1＝唸完）與 InputWordPosition（換詞就回一次 "word"）。
/// ⚠ 只用系統已安裝的合成語音；不錄音、不克隆任何人的聲音。
sealed class SphereVoice : IDisposable
{
    public sealed record Info(string Id, string Name, string Group);

    const int SVSFlagsAsync = 1, SVSFPurgeBeforeSpeak = 2, SVSFIsNotXML = 16;
    const string PrefKey = "sphere.voiceId";
    // SAPI 的 Language 屬性是十六進位 LCID：404＝中文（台灣）、C04＝中文（香港）、804＝中文（中國）
    static readonly (string Lcid, string Group)[] Langs = { ("404", "Windows 內建：中文（台灣）"), ("C04", "Windows 內建：中文（香港）"), ("804", "Windows 內建：中文（中國）") };

    readonly Action<string> onEvent;
    dynamic? sp;                      // SAPI.SpVoice（UI 執行緒建立，STA）
    bool broken;
    List<Info>? cache;
    readonly System.Windows.Forms.Timer poll = new() { Interval = 60 };
    bool speaking, sawRun;
    int lastWord = -1;
    DateTime startedAt;

    public SphereVoice(Action<string> onEvent)
    {
        this.onEvent = onEvent;
        poll.Tick += (_, _) => Tick();
    }

    dynamic? Sp()
    {
        if (sp != null || broken) return sp;
        try
        {
            var t = Type.GetTypeFromProgID("SAPI.SpVoice");
            if (t == null) { broken = true; Log.Note("SPHERE voice: SAPI.SpVoice not registered"); return null; }
            sp = Activator.CreateInstance(t);
        }
        catch (Exception x) { broken = true; Log.Note($"SPHERE voice: SAPI init failed {x.GetType().Name} {x.Message}"); }
        return sp;
    }

    /// 已安裝的中文語音（同名只留一個）。拿不到回空的
    public List<Info> All()
    {
        if (cache != null) return cache;
        var out_ = new List<Info>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (Sp() is { } v)
        {
            foreach (var (lcid, group) in Langs)
            {
                try
                {
                    dynamic tokens = v.GetVoices("Language=" + lcid, "");
                    int n = tokens.Count;
                    for (int i = 0; i < n; i++)
                    {
                        dynamic tok = tokens.Item(i);
                        string id = tok.Id;
                        string name = tok.GetDescription(0);
                        if (seen.Add(id)) out_.Add(new Info(id, name, group));
                    }
                }
                catch (Exception x) { Log.Note($"SPHERE voice: list {lcid} failed {x.Message}"); }
            }
        }
        return cache = out_;
    }

    public string Selected
    {
        get
        {
            var all = All();
            if (BoardPrefs.Str(PrefKey) is { } s && all.Any(v => v.Id == s)) return s;
            return all.FirstOrDefault()?.Id ?? "";
        }
        set => BoardPrefs.Set(PrefKey, value);
    }

    /// 開始唸（非同步）。做不到回原因（呼叫端回 "end"＋說明一次），做得到回 null
    public string? Speak(string text)
    {
        Stop();
        if (Sp() is not { } v) return "這台 Windows 叫不起系統語音（SAPI），球體先不出聲。";
        var id = Selected;
        if (id.Length == 0) return "這台 Windows 沒有安裝中文語音（設定 > 時間與語言 > 語音，加入中文（台灣）），球體先不出聲。";
        try
        {
            dynamic tokens = v.GetVoices("", "");
            int n = tokens.Count;
            for (int i = 0; i < n; i++)
            {
                dynamic tok = tokens.Item(i);
                string tid = tok.Id;
                if (tid == id) { v.Voice = tok; break; }
            }
            v.Rate = 0;
            v.Speak(text, SVSFlagsAsync | SVSFPurgeBeforeSpeak | SVSFIsNotXML);
        }
        catch (Exception x)
        {
            Log.Note($"SPHERE voice: speak failed {x.GetType().Name} {x.Message}");
            return "系統語音唸不出來，球體先不出聲。";
        }
        speaking = true; sawRun = false; lastWord = -1; startedAt = DateTime.UtcNow;
        onEvent("start");
        poll.Start();
        return null;
    }

    void Tick()
    {
        if (!speaking || sp == null) { poll.Stop(); return; }
        try
        {
            dynamic st = sp!.Status;
            int state = st.RunningState;              // 1＝唸完、2＝在唸
            int word = st.InputWordPosition;
            if (state == 2) sawRun = true;
            if (state == 2 && word != lastWord) { lastWord = word; onEvent("word"); }
            // 唸完；或一直沒開始（被別的程式佔住）超過 10 秒就當作結束，網頁才不會卡住
            if ((sawRun && state != 2) || (!sawRun && DateTime.UtcNow - startedAt > TimeSpan.FromSeconds(10))) Finish();
        }
        catch (Exception x) { Log.Note($"SPHERE voice: poll failed {x.Message}"); Finish(); }
    }

    void Finish()
    {
        poll.Stop();
        if (!speaking) return;
        speaking = false;
        onEvent("end");
    }

    public void Stop()
    {
        if (!speaking) return;
        try { sp?.Speak("", SVSFlagsAsync | SVSFPurgeBeforeSpeak); } catch { }
        Finish();
    }

    public void Dispose()
    {
        try { sp?.Speak("", SVSFlagsAsync | SVSFPurgeBeforeSpeak); } catch { }
        speaking = false;
        poll.Dispose();
        if (sp != null) { try { System.Runtime.InteropServices.Marshal.FinalReleaseComObject(sp); } catch { } sp = null; }
    }
}
