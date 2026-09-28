using System.Text.Json;
using Microsoft.Win32.SafeHandles;
using static ShoWork.Native;

namespace ShoWork;

/// Everything the agent knows, driven on the UI thread. Mirrors the Mac Engine: one entry per AI session
/// (keyed by the AI's pid, where the Mac keys by tty), each window shows the most urgent of its sessions.
sealed class Engine
{
    sealed class Tab
    {
        public required int Pid;
        public required long Created;             // pid + creation time = this process, even after pid reuse
        public required string Agent;
        public WorkState State;
        public DateTime Since = DateTime.Now;     // when State last changed (the island shows "for 3 min")
        public long LastStamp;                    // when the AI started the newest hook applied so far
        public IntPtr Console;                   // ConsoleWindowClass or PseudoConsoleWindow; 0 = not resolved yet
        public bool Resolving;
        public RegisteredWaitHandle? Wait;
        public WaitHandle? Process;
        public IntPtr Window => Resolver.WindowOf(Console);
    }

    readonly Control ui;
    readonly Dictionary<int, Tab> tabs = new();
    readonly Dictionary<IntPtr, GlowWindow> glows = new();
    // console of each AI process seen so far, kept after its glow is cleared: the next prompt lights up
    // at once instead of after another helper run. Pruned when the process is gone.
    readonly Dictionary<(int pid, long created), IntPtr> consoles = new();
    readonly System.Windows.Forms.Timer watchdog = new() { Interval = 250 };
    readonly ClearWatcher clear;
    readonly List<IntPtr> winHooks = new();
    readonly WinEventProc winEventProc;          // keep the delegate alive while the hooks exist
    readonly EdgeGlow edge = new();              // full-screen edge line (W2)
    Tray? tray;
    bool checkingSelection;

    static string SupportDir => Wire.SupportDir;
    static string StatePath => Path.Combine(SupportDir, "state.json");

    // MARK: seams for the tray / island / settings / arranger (W2–W3)

    /// Fired on the UI thread after every render (state, window or glow changes).
    public event Action? Changed;
    /// Fired on the UI thread when a session enters a new state (before render): session, previous state.
    public event Action<SessionView, WorkState>? StateChanged;

    /// Every AI session the agent knows, most urgent first.
    public IReadOnlyList<SessionView> Sessions =>
        tabs.Values.Select(View).OrderByDescending(s => StateMachine.Priority(s.State)).ThenBy(s => s.Since).ToList();

    static SessionView View(Tab t) { var w = t.Window; return new SessionView(t.Pid, t.Agent, t.State, w, w == IntPtr.Zero ? "" : TitleOf(w), t.Since); }

    /// Bring a window to the front because the user asked for it (clicked it in the island/menu).
    public static void JumpTo(IntPtr window)
    {
        if (!IsWindow(window)) return;
        if (IsIconic(window)) ShowWindow(window, 9 /*SW_RESTORE*/);
        SetForegroundWindow(window);
    }

    public Engine(Control ui)
    {
        this.ui = ui;
        clear = new ClearWatcher(Looked);
        winEventProc = OnWinEvent;
        watchdog.Tick += (_, _) => Tick();
        GlowSettings.Shared.Changed += SettingsChanged;             // W2 settings
    }

    /// W2: a look changed in the settings window — restyle every glow; an off state now lights nothing.
    void SettingsChanged()
    {
        foreach (var g in glows.Values) if (!g.IsDisposed) g.Restyle();
        Render();
    }

    public void Start(Action reload, Action quit)
    {
        tray = new Tray(this, reload, quit);
        Restore();
        Render();
    }

    public void Stop()
    {
        watchdog.Stop();
        clear.Enable(false);
        HookWinEvents(false);
        foreach (var g in glows.Values) g.Close();
        glows.Clear();
        edge.Dispose();
        tray?.Dispose();
    }

    // MARK: events

    public void Handle(WireMessage m)
    {
        var created = CreationTime(m.Pid);
        if (created == 0) { Log.Note($"EVT {PipeServer.Describe(m)} ignored: process is gone"); return; }
        if (tabs.TryGetValue(m.Pid, out var t) && t.Created != created) { Drop(t); t = null; }   // pid reused
        if (t == null)
        {
            if (m.Event == WorkEvent.Clear) return;
            t = new Tab { Pid = m.Pid, Created = created, Agent = m.Agent };
            foreach (var k in consoles.Keys.Where(k => CreationTime(k.pid) != k.created).ToList()) consoles.Remove(k);
            if (consoles.TryGetValue((m.Pid, created), out var known) && IsWindow(known)) t.Console = known;
            if (!Watch(t)) return;
            tabs[m.Pid] = t;
        }
        // async hooks race: a PostToolUse "working" started before Stop may land after it
        if (m.Stamp != 0 && m.Stamp < t.LastStamp) { Log.Note($"EVT {PipeServer.Describe(m)} dropped: older than the last event"); return; }
        if (m.Stamp != 0) t.LastStamp = m.Stamp;
        var before = t.State;
        t.State = StateMachine.Next(t.State, m.Event);
        if (t.State != before) { t.Since = DateTime.Now; StateChanged?.Invoke(View(t), before); }
        Log.Note($"EVT {PipeServer.Describe(m)} {before}→{t.State} console={t.Console} window={t.Window}");
        if (t.State == WorkState.Idle) Drop(t);
        else if (t.Console == IntPtr.Zero || !IsWindow(t.Console)) Resolve(t);
        Render();
    }

    /// Open the AI process once and get told the moment it exits (no polling: the Mac reaper's 5 s loop
    /// becomes a kernel wait). /exit sends SessionEnd anyway; this covers crashes and closed windows.
    bool Watch(Tab t)
    {
        var h = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, false, (uint)t.Pid);
        if (h == IntPtr.Zero) return false;
        var wh = new ProcessWait(h);
        t.Process = wh;
        t.Wait = ThreadPool.RegisterWaitForSingleObject(wh, (_, _) =>
        {
            try { ui.BeginInvoke(() => Reap(t)); } catch { }
        }, null, Timeout.Infinite, executeOnlyOnce: true);
        return true;
    }

    sealed class ProcessWait : WaitHandle
    {
        public ProcessWait(IntPtr h) => SafeWaitHandle = new SafeWaitHandle(h, ownsHandle: true);
    }

    void Reap(Tab t)
    {
        if (!tabs.TryGetValue(t.Pid, out var cur) || cur != t) return;
        Log.Note($"REAP pid={t.Pid} {t.State}: process exited");
        Drop(t);
        Render();
    }

    void Drop(Tab t)
    {
        tabs.Remove(t.Pid);
        t.Wait?.Unregister(null);
        t.Process?.Dispose();
    }

    void Resolve(Tab t)
    {
        if (t.Resolving) return;
        t.Resolving = true;
        Task.Run(() => Resolver.Consoles(new[] { t.Pid })).ContinueWith(r =>
        {
            t.Resolving = false;
            var info = r.Result.FirstOrDefault(x => x.Pid == t.Pid);
            t.Console = info.Hwnd;
            if (info.Hwnd != IntPtr.Zero) consoles[(t.Pid, t.Created)] = info.Hwnd;
            Log.Note($"RESOLVE pid={t.Pid} console={info.Hwnd} [{(info.Hwnd == IntPtr.Zero ? "" : ClassOf(info.Hwnd))}] window={t.Window}");
            if (tabs.ContainsKey(t.Pid)) Render();
        }, TaskScheduler.FromCurrentSynchronizationContext());
    }

    /// A key or click went to `window`. Green there is seen — for a WT window with several panes, only the
    /// pane on screen (see Resolver.LooksSelected); red stays until the AI moves on.
    void Looked(IntPtr window)
    {
        Log.Note($"LOOKED {window} [{ClassOf(window)}]");
        var greens = tabs.Values.Where(t => t.State == WorkState.Done && t.Window == window).ToList();
        if (greens.Count == 0) return;
        var panes = Resolver.IsTerminal(window) ? Resolver.PanesOf(window) : new List<IntPtr>();
        if (panes.Count <= 1) { Acknowledge(greens, "only pane"); return; }
        if (checkingSelection) return;
        checkingSelection = true;
        var panePids = panes.ToDictionary(p => p, p => { GetWindowThreadProcessId(p, out var pid); return (int)pid; });
        var ask = greens.Select(g => g.Pid).Concat(panePids.Values).Where(p => p > 0).Distinct().ToList();
        Task.Run(() => Resolver.Consoles(ask)).ContinueWith(r =>
        {
            checkingSelection = false;
            var title = r.Result.GroupBy(x => x.Pid).ToDictionary(x => x.Key, x => x.First().Title);
            var windowTitle = TitleOf(window);
            var seen = greens.Where(g =>
            {
                var mine = title.GetValueOrDefault(g.Pid, "");
                var others = panes.Where(p => p != g.Console).Select(p => title.GetValueOrDefault(panePids[p], "")).Where(s => s.Length > 0);
                var sel = Resolver.LooksSelected(windowTitle, mine, others);
                Log.Note($"SELECTED? pid={g.Pid} window='{windowTitle}' mine='{mine}' others=[{string.Join("|", others)}] → {sel}");
                return sel;
            }).ToList();
            Acknowledge(seen, "title match");
        }, TaskScheduler.FromCurrentSynchronizationContext());
    }

    void Acknowledge(List<Tab> seen, string why)
    {
        bool changed = false;
        foreach (var t in seen)
        {
            if (!tabs.ContainsKey(t.Pid) || t.State != WorkState.Done) continue;
            var was = t.State;
            t.State = StateMachine.Acknowledge(t.State);
            StateChanged?.Invoke(View(t), was);
            Log.Note($"ACK pid={t.Pid} ({why})");
            if (t.State == WorkState.Idle) Drop(t);
            changed = true;
        }
        if (changed) Render();
    }

    // MARK: rendering

    Dictionary<IntPtr, WorkState> WindowStates()
    {
        var want = new Dictionary<IntPtr, WorkState>();
        foreach (var t in tabs.Values)
        {
            var w = t.Window;
            if (w == IntPtr.Zero || !GlowSettings.Shared.Look(t.State).Enabled) continue;   // off ⇒ the next lit state shows
            want[w] = StateMachine.WindowState(new[] { want.GetValueOrDefault(w), t.State });
        }
        return want;
    }

    void Render()
    {
        var want = WindowStates();
        foreach (var (w, g) in glows.ToList())
            if (!want.ContainsKey(w) || g.IsDisposed) { if (!g.IsDisposed) g.Close(); glows.Remove(w); }
        foreach (var (w, s) in want)
        {
            if (!glows.TryGetValue(w, out var g))
            {
                g = new GlowWindow(w, s);
                glows[w] = g;
                g.Show();
                g.Sync();
            }
            else g.SetState(s);
        }
        UpdateEdge();
        HookWinEvents(glows.Count > 0);
        if (tabs.Count > 0) watchdog.Start(); else watchdog.Stop();
        clear.Enable(tabs.Values.Any(t => t.State == WorkState.Done && t.Window != IntPtr.Zero));
        tray?.Update(tabs.Values.Count(t => t.State == WorkState.Working), tabs.Values.Count(t => t.State == WorkState.Done),
                     tabs.Values.Count(t => t.State == WorkState.Input));
        Save();
        StatusFile();
        Changed?.Invoke();
    }

    /// 4 Hz while any session exists: a WT tab dragged to another window changes the pseudo window's owner
    /// without any event, a console can go away, and the W0 stacking check.
    void Tick()
    {
        foreach (var t in tabs.Values)
            if (t.Console != IntPtr.Zero && !IsWindow(t.Console)) { t.Console = IntPtr.Zero; Resolve(t); }
        var want = WindowStates();
        if (want.Count != glows.Count || want.Any(kv => !glows.TryGetValue(kv.Key, out var g) || g.IsDisposed || g.State != kv.Value))
        {
            Render();
            return;
        }
        foreach (var g in glows.Values) if (!g.StackedRight) g.Sync();
        UpdateEdge();
    }

    /// The edge also changes outside Render (foreground / location events): keep the test status file current.
    void UpdateEdge() { if (edge.Update(glows.Values)) StatusFile(); }

    void HookWinEvents(bool on)
    {
        if (on == winHooks.Count > 0) return;
        if (on)
        {
            foreach (var (lo, hi) in new[] {
                         (EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND),
                         (EVENT_SYSTEM_MINIMIZESTART, EVENT_SYSTEM_MINIMIZEEND),
                         (EVENT_OBJECT_DESTROY, EVENT_OBJECT_DESTROY),
                         (EVENT_OBJECT_REORDER, EVENT_OBJECT_REORDER),
                         (EVENT_OBJECT_LOCATIONCHANGE, EVENT_OBJECT_LOCATIONCHANGE) })
                winHooks.Add(SetWinEventHook(lo, hi, IntPtr.Zero, winEventProc, 0, 0, WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS));
        }
        else
        {
            foreach (var h in winHooks) UnhookWinEvent(h);
            winHooks.Clear();
        }
    }

    void OnWinEvent(IntPtr hook, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time)
    {
        if (idObject != OBJID_WINDOW && ev != EVENT_SYSTEM_FOREGROUND) return;   // carets, cursors…
        bool any = ev == EVENT_SYSTEM_FOREGROUND || ev == EVENT_OBJECT_REORDER;
        foreach (var g in glows.Values)
            if (!g.IsDisposed && (any || hwnd == g.Target)) g.Sync();
        if (ev == EVENT_OBJECT_DESTROY && glows.ContainsKey(hwnd)) Render();
        // full screen starts/ends with a foreground change or the front window resizing (F11)
        else if (ev != EVENT_OBJECT_REORDER && (ev != EVENT_OBJECT_LOCATIONCHANGE || hwnd == GetForegroundWindow() || glows.ContainsKey(hwnd))) UpdateEdge();
    }

    // MARK: persistence — an agent restart (reload, update, crash) must not forget who is working

    sealed record Saved(int Pid, long Created, string Agent, string State);

    void Save()
    {
        try
        {
            Directory.CreateDirectory(SupportDir);
            var s = tabs.Values.Select(t => new Saved(t.Pid, t.Created, t.Agent, t.State.ToString())).ToList();
            var tmp = StatePath + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(s));
            File.Move(tmp, StatePath, overwrite: true);
        }
        catch (Exception e) { Log.Note($"SAVE {e.Message}"); }
    }

    void Restore()
    {
        try
        {
            if (!File.Exists(StatePath)) return;
            foreach (var x in JsonSerializer.Deserialize<List<Saved>>(File.ReadAllText(StatePath)) ?? new())
            {
                if (!Enum.TryParse<WorkState>(x.State, out var st) || st == WorkState.Idle || !Wire.ValidAgent(x.Agent)) continue;
                if (CreationTime(x.Pid) != x.Created) continue;                 // gone, or the pid belongs to someone else now
                var t = new Tab { Pid = x.Pid, Created = x.Created, Agent = x.Agent, State = st };
                if (!Watch(t)) continue;
                tabs[t.Pid] = t;
                Resolve(t);
                Log.Note($"RESTORE pid={t.Pid} {st}");
            }
        }
        catch (Exception e) { Log.Note($"RESTORE {e.Message}"); }
    }

    /// SHOWORK_STATUS_FILE: what the agent believes, for the e2e tests. Never read by anything critical.
    void StatusFile()
    {
        var path = Environment.GetEnvironmentVariable("SHOWORK_STATUS_FILE");
        if (string.IsNullOrEmpty(path)) return;
        try
        {
            var o = new
            {
                tabs = tabs.Values.Select(t => new { pid = t.Pid, agent = t.Agent, state = t.State.ToString().ToLowerInvariant(), console = t.Console.ToInt64(), window = t.Window.ToInt64() }),
                glows = glows.Where(g => !g.Value.IsDisposed).Select(g => new { target = g.Key.ToInt64(), glow = g.Value.Handle.ToInt64(), state = g.Value.State.ToString().ToLowerInvariant() }),
                clearWatcher = clear.Active,
                edge = edge.State.ToString().ToLowerInvariant(),
            };
            File.WriteAllText(path + ".tmp", JsonSerializer.Serialize(o));
            // a test reading the file at that instant makes the replace fail: retry briefly
            for (int i = 0; ; i++)
            {
                try { File.Move(path + ".tmp", path, overwrite: true); break; }
                catch (IOException) when (i < 10) { Thread.Sleep(10); }
            }
        }
        catch { }
    }
}

/// What the tray, island and menus show about one AI session.
public readonly record struct SessionView(int Pid, string Agent, WorkState State, IntPtr Window, string Title, DateTime Since);
