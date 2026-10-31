using System.Text.Json;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace ShoWork;

/// 戰情中心的「大樓」檢視（W6）：WebView2 ＋ Board\Web\office.html（three.js，vendor 在 repo 裡，離線可用）。
/// 資料：BoardForm 把卡片組成 OfficeSnapshot JSON（Board\Office.cs），這裡用 PostWebMessageAsJson 推過去；頁面只畫、不讀檔。
/// 頁面 → 這裡：{type:"ready"}（載好了，補推最新資料）、{type:"select", id}（點了角色；id null＝點空白）。
/// 網頁檔：開發 build 在 exe 旁邊的 Web\；單一 exe／安裝版沒有那個資料夾 ⇒ 從內嵌資源解到 %LOCALAPPDATA%\ShoWork42\office-web\<組件版本>\。
/// WebView2 Runtime 不在（Win10 沒裝、被移除）、或初始化失敗、或瀏覽器行程掛掉：Failed 事件 ⇒ BoardForm 退回卡片畫面，不丟例外。
sealed class OfficeHost : IDisposable
{
    /// 虛擬主機名（只對應到本機資料夾；.invalid 保證不是真的網域）
    public const string HostName = "office.showork42.invalid";

    readonly WebView2 view = new() { Dock = DockStyle.Fill, DefaultBackgroundColor = Color.FromArgb(0x14, 0x1B, 0x26) };
    string? latest;                  // 最新的 JSON（頁面還沒 ready 時先存著）
    string? sent;
    bool ready, started, disposed;

    public Control View => view;
    public bool Failed { get; private set; }
    /// 點了角色（null＝點空白處）
    public event Action<string?>? Selected;
    /// 不能用了（原因一行），BoardForm 收到就退回卡片
    public event Action<string>? Broken;

    /// WebView2 Runtime 在不在（版本字串；不在回 null）。Win11 內建；只查一次
    public static string? RuntimeVersion => runtime.Value;
    static readonly Lazy<string?> runtime = new(() =>
    {
        if (Environment.GetEnvironmentVariable("SHOWORK_OFFICE_NO_WEBVIEW") is "1") return null;   // 測試退回卡片用
        try { return CoreWebView2Environment.GetAvailableBrowserVersionString(); }
        catch (Exception x) { Log.Note($"OFFICE webview2 runtime missing: {x.GetType().Name} {x.Message}"); return null; }
    });

    /// 開始載入（只做一次）。失敗不丟例外：觸發 Broken
    public async void Start()
    {
        if (started || disposed) return;
        started = true;
        try
        {
            var folder = WebFolder() ?? throw new FileNotFoundException("office.html 不在 Web\\ 也不在內嵌資源");
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
            // 只准看自己的頁面：別的網址（頁面裡不該有，但保險）一律擋掉、不開新視窗
            core.NavigationStarting += (_, e) => { if (!e.Uri.StartsWith($"https://{HostName}/", StringComparison.OrdinalIgnoreCase)) e.Cancel = true; };
            core.NewWindowRequested += (_, e) => e.Handled = true;
            core.WebMessageReceived += OnMessage;
            core.ProcessFailed += (_, e) => Fail($"WebView2 process failed: {e.ProcessFailedKind}");
            // 自己的頁面載不起來才算壞掉（被上面擋掉的導覽是 OperationCanceled，不算）
            core.NavigationCompleted += (_, e) =>
            {
                if (!e.IsSuccess && !ready && e.WebErrorStatus != CoreWebView2WebErrorStatus.OperationCanceled) Fail($"office.html 載入失敗：{e.WebErrorStatus}");
            };
            Log.Note($"OFFICE start runtime={RuntimeVersion} folder={folder}");
            core.Navigate($"https://{HostName}/office.html");
        }
        catch (Exception x) { Fail($"WebView2 init failed: {x.GetType().Name} {x.Message}"); }
    }

    void Fail(string why)
    {
        if (Failed || disposed) return;
        Failed = true;
        Log.Note("OFFICE " + why);
        Broken?.Invoke(why);
    }

    void OnMessage(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        try
        {
            using var doc = JsonDocument.Parse(e.WebMessageAsJson);
            var r = doc.RootElement;
            switch (r.TryGetProperty("type", out var t) ? t.GetString() : null)
            {
                case "ready":
                    ready = true;
                    sent = null;
                    Flush();
                    break;
                case "select":
                    Selected?.Invoke(r.TryGetProperty("id", out var id) && id.ValueKind == JsonValueKind.String ? id.GetString() : null);
                    break;
            }
        }
        catch (Exception x) { Log.Note($"OFFICE bad message: {x.Message}"); }
    }

    /// 推資料（內容沒變就不推）
    public void Push(string json)
    {
        latest = json;
        Flush();
    }

    void Flush()
    {
        if (!ready || disposed || Failed || latest == null || latest == sent || view.CoreWebView2 == null) return;
        try { view.CoreWebView2.PostWebMessageAsJson(latest); sent = latest; }
        catch (Exception x) { Fail($"post failed: {x.Message}"); }
    }

    /// WinForms 那邊關掉了細節卡：頁面上的選取框也拿掉
    public void Deselect()
    {
        if (!ready || Failed || view.CoreWebView2 == null) return;
        try { view.CoreWebView2.PostWebMessageAsJson("{\"type\":\"deselect\"}"); } catch { }
    }

    // MARK: 網頁檔的位置

    /// exe 旁邊的 Web\（dotnet build 會複製過去）；沒有就把內嵌資源解到 SupportDir（單一 exe、安裝版）
    static string? WebFolder()
    {
        var dev = Path.Combine(AppContext.BaseDirectory, "Web");
        if (File.Exists(Path.Combine(dev, "office.html"))) return dev;
        var asm = typeof(OfficeHost).Assembly;
        var names = asm.GetManifestResourceNames().Where(n => n.Replace('\\', '/').StartsWith("Web/", StringComparison.Ordinal)).ToList();
        if (names.Count == 0) return null;
        // 每個版本一個資料夾（組件的 MVID）：更新後不會用到舊檔
        var dir = Path.Combine(Wire.SupportDir, "office-web", asm.ManifestModule.ModuleVersionId.ToString("N")[..12]);
        foreach (var n in names)
        {
            var rel = n.Replace('\\', '/')["Web/".Length..];
            if (rel.Contains("..")) continue;
            var path = Path.Combine(dir, rel.Replace('/', Path.DirectorySeparatorChar));
            if (File.Exists(path)) continue;
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            using var src = asm.GetManifestResourceStream(n)!;
            var tmp = path + $".{Environment.ProcessId}.tmp";
            using (var dst = File.Create(tmp)) src.CopyTo(dst);
            File.Move(tmp, path, overwrite: true);
        }
        return File.Exists(Path.Combine(dir, "office.html")) ? dir : null;
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        try { view.Dispose(); } catch { }
    }
}
