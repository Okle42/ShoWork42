# ShoWork42 Windows W2 驗收：系統匣動態島（彈出面板、膠囊通知、系統匣圖示脈動）
# 只碰本腳本自己開的兩個測試主控台視窗和自己啟動的 agent（白名單）；其他視窗前後位置逐一比對。
# 測試視窗用 SW_SHOWNOACTIVATE 開，不搶使用者的前景視窗。
# 用法：powershell -ExecutionPolicy Bypass -File w2_island.ps1 -Agent <ShoWorkAgent.exe> -Out <資料夾>
param([string]$Agent, [string]$Out)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $Out | Out-Null
$showork = Join-Path (Split-Path $Agent) 'showork.exe'
Add-Type -ReferencedAssemblies System.Drawing @'
using System; using System.Runtime.InteropServices; using System.Collections.Generic; using System.Drawing; using System.Text;
public static class T {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  public delegate bool CB(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(CB cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  public static string Cls(IntPtr h) { var s = new StringBuilder(256); GetClassName(h, s, 256); return s.ToString(); }
  public static uint Pid(IntPtr h) { uint p; GetWindowThreadProcessId(h, out p); return p; }
  public static RECT Rect(IntPtr h) { RECT r; GetWindowRect(h, out r); return r; }
  public static List<IntPtr> All() { var l = new List<IntPtr>(); EnumWindows((h, x) => { l.Add(h); return true; }, IntPtr.Zero); return l; }
  public static List<IntPtr> Of(uint pid) { var l = new List<IntPtr>(); foreach (var h in All()) if (Pid(h) == pid) l.Add(h); return l; }
  // visible windows of the agent: pill = NOACTIVATE without TRANSPARENT; flyout = neither; glow = TRANSPARENT
  public static IntPtr Find(uint pid, bool pill) {
    foreach (var h in Of(pid)) {
      if (!IsWindowVisible(h)) continue; int ex = GetWindowLong(h, -20);
      bool noact = (ex & 0x8000000) != 0, transp = (ex & 0x20) != 0;
      if (transp) continue; if (pill == noact) return h; }
    return IntPtr.Zero; }
  public static int ExStyle(IntPtr h) { return GetWindowLong(h, -20); }
  public static void Shot(RECT r, int m, string path) {
    int x = r.L - m, y = r.T - m, w = r.R - r.L + 2 * m, h = r.B - r.T + 2 * m;
    using (var b = new Bitmap(w, h)) { using (var g = Graphics.FromImage(b)) g.CopyFromScreen(x, y, 0, 0, new Size(w, h)); b.Save(path); } }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct SI { public int cb; public string r, d, t; public int x, y, xs, ys, xc, yc, fill, flags; public short show, r2; public IntPtr r3, i, o, e; }
  [StructLayout(LayoutKind.Sequential)] struct PI { public IntPtr hp, ht; public int pid, tid; }
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  static extern bool CreateProcess(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inh, uint flags, IntPtr env, string dir, ref SI si, out PI pi);
  // STARTF_USESHOWWINDOW + SW_SHOWNOACTIVATE
  public static int Start(string cmd) { var si = new SI(); si.cb = Marshal.SizeOf(si); si.flags = 1; si.show = 4; PI pi;
    if (!CreateProcess(null, new StringBuilder(cmd), IntPtr.Zero, IntPtr.Zero, false, 0, IntPtr.Zero, null, ref si, out pi)) throw new Exception("CreateProcess " + Marshal.GetLastWin32Error());
    return pi.pid; }
}
'@
[T]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
$pass = 0; $fail = 0; $lines = New-Object System.Collections.Generic.List[string]
function Check($name, $ok, $detail) {
  if ($ok) { $script:pass++ } else { $script:fail++ }
  $l = "{0} {1} {2}" -f ($(if ($ok) {'PASS'} else {'FAIL'})), $name, $detail; $lines.Add($l); Write-Host $l
}
function Info($l) { $lines.Add("INFO $l"); Write-Host "INFO $l" }
function Snapshot { $d = @{}; foreach ($h in [T]::All()) { if ([T]::IsWindowVisible($h)) { $r = [T]::Rect($h); $d[[long]$h] = "$($r.L),$($r.T),$($r.R),$($r.B)" } }; $d }
function Usage($secs) {
  $p = Get-Process -Id $agentProc.Id; $c0 = $p.TotalProcessorTime.TotalMilliseconds; Start-Sleep $secs
  $p = Get-Process -Id $agentProc.Id; $c1 = $p.TotalProcessorTime.TotalMilliseconds
  return @{ cpu = ($c1 - $c0) / ($secs * 10); ws = $p.WorkingSet64 / 1MB }       # % of one core
}
function Emit($ev, $target) { & $showork emit $ev --agent claude --pid $target }
function Pill { [T]::Find([uint32]$agentProc.Id, $true) }
function Island { [T]::Find([uint32]$agentProc.Id, $false) }
# fake a left click on our own tray icon: the NotifyIcon callback message to the agent's own windows
function OpenIsland { foreach ($h in [T]::Of([uint32]$agentProc.Id)) { [T]::PostMessage($h, 0x800, [IntPtr]1, [IntPtr]0x201) | Out-Null; [T]::PostMessage($h, 0x800, [IntPtr]1, [IntPtr]0x202) | Out-Null }; Start-Sleep -Milliseconds 800; Island }
function PillCount { [regex]::Matches((Get-Content (Join-Path $home_ 'agent.log') -Raw), 'PILL pid').Count }

$before = Snapshot
$home_ = Join-Path $Out 'home'; New-Item -ItemType Directory -Force $home_ | Out-Null
$env:SHOWORK_PIPE = "SW42-w2-island-$PID"; $env:SHOWORK_HOME = $home_; $env:SHOWORK_DEBUG = '1'; $env:SHOWORK_STATUS_FILE = Join-Path $Out 'status.json'
$agentProc = Start-Process $Agent -PassThru
Start-Sleep 3
$u = Usage 5
Check ("idle CPU {0:N2}% of a core, WS {1:N1} MB" -f $u.cpu, $u.ws) ($u.cpu -lt 1 -and $u.ws -lt 60) ''

# C first, B last: the newest window tends to end up in front, and the pill must skip that one
$conC = [T]::Start("conhost.exe powershell.exe -NoExit -NoProfile -Command `$host.UI.RawUI.WindowTitle='SW42 island C'")
$conA = [T]::Start("conhost.exe powershell.exe -NoExit -NoProfile -Command `$host.UI.RawUI.WindowTitle='SW42 island A'")
$conB = [T]::Start("conhost.exe powershell.exe -NoExit -NoProfile -Command `$host.UI.RawUI.WindowTitle='SW42 island B'")
Start-Sleep 3
$psA = (Get-CimInstance Win32_Process -Filter "ParentProcessId=$conA AND Name='powershell.exe'").ProcessId
$psB = (Get-CimInstance Win32_Process -Filter "ParentProcessId=$conB AND Name='powershell.exe'").ProcessId
$psC = (Get-CimInstance Win32_Process -Filter "ParentProcessId=$conC AND Name='powershell.exe'").ProcessId
Check 'test consoles' ($psA -and $psB -and $psC) "A=$psA B=$psB C=$psC front=$([T]::Pid([T]::GetForegroundWindow()))"
$mine = @(foreach ($p in @($conA, $conB, $conC, $psA, $psB, $psC)) { [T]::Of([uint32]$p) }) | ForEach-Object { [long]$_ }

try {
  # 1. pill on done
  Emit working $psA; Start-Sleep 1.5
  Check 'no pill while working' ((Pill) -eq [IntPtr]::Zero) ''
  $u = Usage 6
  Info ("purple: W1 glow breathing (30 fps), tray icon still: CPU {0:N2}% of a core, WS {1:N1} MB" -f $u.cpu, $u.ws)
  Emit done $psA; Start-Sleep -Milliseconds 700
  $pill = Pill
  Check 'pill shows on done' ($pill -ne [IntPtr]::Zero) ''
  Check 'pill did not take the foreground' ([T]::Pid([T]::GetForegroundWindow()) -ne $agentProc.Id) ''
  if ($pill -ne [IntPtr]::Zero) {
    Check 'pill is NOACTIVATE|TOPMOST|LAYERED|TOOLWINDOW' (([T]::ExStyle($pill) -band 0x8080088) -eq 0x8080088) ('0x{0:X}' -f [T]::ExStyle($pill))
    [T]::Shot([T]::Rect($pill), 24, (Join-Path $Out 'pill-done.png'))
  }
  Start-Sleep 5
  Check 'pill auto-hides after ~4 s' ((Pill) -eq [IntPtr]::Zero) ''

  # 2. burst: A input + C done together -> one pill for the red one, "+1"; B (in front) done -> no pill of its own
  Emit working $psB; Emit working $psC; Start-Sleep 1
  Emit input $psA; Emit done $psC; Start-Sleep -Milliseconds 900
  $pill = Pill
  $log = Get-Content (Join-Path $home_ 'agent.log') -Raw
  Check 'burst -> exactly one more pill, red, +1' ($pill -ne [IntPtr]::Zero -and (PillCount) -eq 2 -and $log -match "PILL pid=$psA Input \+1") "pills=$(PillCount)"
  if ($pill -ne [IntPtr]::Zero) { [T]::Shot([T]::Rect($pill), 24, (Join-Path $Out 'pill-burst.png')) }
  $fg = [T]::GetForegroundWindow()
  if ([T]::Pid($fg) -eq $conB -or [T]::Pid($fg) -eq $psB) {
    Emit done $psB; Start-Sleep -Milliseconds 900
    $log = Get-Content (Join-Path $home_ 'agent.log') -Raw
    Check 'no pill for the window in front (B)' ($log -notmatch "PILL pid=$psB") ''
  } else { $lines.Add("SKIP front-window check: B is not in front") }
  Start-Sleep 5

  # 3. red pulse cost (tray icon frames at ~3 fps)
  $u = Usage 10
  Info ("red: 3 glows + tray pulse (~3 fps): CPU {0:N2}% of a core, WS {1:N1} MB" -f $u.cpu, $u.ws)

  # 4. island flyout, live update, close
  $fly = OpenIsland
  Check 'island opens' ($fly -ne [IntPtr]::Zero) ''
  if ($fly -ne [IntPtr]::Zero) {
    [T]::Shot([T]::Rect($fly), 16, (Join-Path $Out 'island-2.png'))
    $m = [regex]::Match((Get-Content (Join-Path $home_ 'agent.log') -Raw), 'ISLAND open anchor=\{X=(-?\d+),Y=(-?\d+),Width=(\d+),Height=(\d+)')
    if ($m.Success) { $r = New-Object T+RECT; $r.L = [int]$m.Groups[1].Value; $r.T = [int]$m.Groups[2].Value; $r.R = $r.L + [int]$m.Groups[3].Value; $r.B = $r.T + [int]$m.Groups[4].Value; [T]::Shot($r, 8, (Join-Path $Out 'tray-icon.png')) }
    Emit working $psB; Start-Sleep -Milliseconds 600
    [T]::Shot([T]::Rect($fly), 16, (Join-Path $Out 'island-live.png'))
    $u = Usage 3
    Info ("island open over 3 glows: CPU {0:N2}% of a core, WS {1:N1} MB" -f $u.cpu, $u.ws)
    Emit done $psB; Start-Sleep -Milliseconds 600
    Check 'no pill while the island is open' ((PillCount) -eq 2) "pills=$(PillCount)"
    [T]::PostMessage($fly, 0x10, [IntPtr]0, [IntPtr]0) | Out-Null; Start-Sleep -Milliseconds 500
    Check 'island closes' ((Island) -eq [IntPtr]::Zero) ''
  }
  Emit clear $psA; Emit clear $psB; Emit clear $psC; Start-Sleep 1
  $fly = OpenIsland
  Check 'empty island opens' ($fly -ne [IntPtr]::Zero) ''
  if ($fly -ne [IntPtr]::Zero) {
    [T]::Shot([T]::Rect($fly), 16, (Join-Path $Out 'island-empty.png'))
    $u = Usage 5
    Check ("island open alone (1 s refresh) CPU {0:N2}% of a core, WS {1:N1} MB" -f $u.cpu, $u.ws) ($u.cpu -lt 1 -and $u.ws -lt 60) ''
    [T]::PostMessage($fly, 0x10, [IntPtr]0, [IntPtr]0) | Out-Null
  }
  Start-Sleep 3
  $u = Usage 6
  Check ("idle again CPU {0:N2}% of a core, WS {1:N1} MB" -f $u.cpu, $u.ws) ($u.cpu -lt 1 -and $u.ws -lt 60) ''
}
finally {
  Stop-Process -Id $agentProc.Id -ErrorAction SilentlyContinue
  foreach ($p in @($psA, $psB, $psC, $conA, $conB, $conC)) { if ($p) { Stop-Process -Id $p -ErrorAction SilentlyContinue } }
}
Start-Sleep 1
$after = Snapshot
$moved = @($before.Keys | Where-Object { $after.ContainsKey($_) -and $after[$_] -ne $before[$_] -and ($mine -notcontains $_) })
Check 'no other window moved or resized' ($moved.Count -eq 0) (($moved | ForEach-Object { "$_ $($before[$_]) -> $($after[$_]) [$([T]::Cls([IntPtr]$_))]" }) -join '; ')
$lines.Add("TOTAL pass=$pass fail=$fail")
$lines | Out-File (Join-Path $Out 'result.txt') -Encoding utf8
