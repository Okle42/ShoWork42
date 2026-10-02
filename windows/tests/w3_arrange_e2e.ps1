# ShoWork42 Windows W3 驗收：自動排版（每台螢幕各自排）
# 只動本腳本自己開的 conhost 測試視窗：agent 以 SHOWORK_ONLY_WIDS＋SHOWORK_ARRANGE_ONLY_LISTED=1 啟動，候選只有白名單。
# 測試視窗以最小化開啟，之後只用 SW_SHOWNOACTIVATE／SW_SHOWMINNOACTIVE 切換；排版前後前景視窗必須不變。
# 其他所有可見視窗的位置大小前後比對必須完全相同。
# 用法：powershell -ExecutionPolicy Bypass -File w3_arrange_e2e.ps1 [-Agent ShoWorkAgent.exe] [-Out 結果檔]
param([string]$Agent = "$PSScriptRoot\..\ShoWork.Win\bin\Release\net8.0-windows\ShoWorkAgent.exe",
      [string]$Out = "$env:TEMP\sw42_w3_result.txt")
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'guard.ps1')
$Agent = (Resolve-Path $Agent).Path
Add-Type @'
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class W3 {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int cb; public RECT mon, work; public uint flags; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential)] public struct WINDOWPLACEMENT { public int length, flags, showCmd; public POINT min, max; public RECT normal; }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct STARTUPINFO {
    public int cb; public string r, desk, title; public int x, y, xs, ys, xc, yc, fill, flags; public short show, r2; public IntPtr r3, i, o, e; }
  [StructLayout(LayoutKind.Sequential)] public struct PROCINFO { public IntPtr hp, ht; public int pid, tid; }
  public delegate bool CB(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(CB cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint c);
  [DllImport("user32.dll")] public static extern IntPtr GetTopWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr h, ref WINDOWPLACEMENT p);
  [DllImport("user32.dll")] public static extern bool SetWindowPlacement(IntPtr h, ref WINDOWPLACEMENT p);
  [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h, uint f);
  [DllImport("user32.dll")] public static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO mi);
  [DllImport("shcore.dll")] public static extern int GetDpiForMonitor(IntPtr m, int t, out uint x, out uint y);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int s);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  public static extern bool CreateProcess(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, int flags, IntPtr env, string dir, ref STARTUPINFO si, out PROCINFO pi);
  public static RECT Vis(IntPtr h) { RECT r; if (DwmGetWindowAttribute(h, 9, out r, 16) != 0) GetWindowRect(h, out r); return r; }
  public static string Cls(IntPtr h) { var s = new StringBuilder(256); GetClassName(h, s, 256); return s.ToString(); }
  public static string Title(IntPtr h) { var s = new StringBuilder(256); GetWindowText(h, s, 256); return s.ToString(); }
  public static List<IntPtr> Top() { var l = new List<IntPtr>(); EnumWindows((h, x) => { l.Add(h); return true; }, IntPtr.Zero); return l; }
  /// conhost started minimised with SW_SHOWMINNOACTIVE: nothing of the user is moved or restored; a new process may still take the foreground
  public static int Launch(string cmd) {
    var si = new STARTUPINFO(); si.cb = Marshal.SizeOf(si); si.flags = 1; si.show = 7; PROCINFO pi;
    if (!CreateProcess(null, new StringBuilder(cmd), IntPtr.Zero, IntPtr.Zero, false, 0 /*conhost is a GUI-subsystem exe*/, IntPtr.Zero, null, ref si, out pi)) return 0;
    return pi.pid;
  }
}
'@
# physical pixels like the agent (Per-Monitor V2)
[W3]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
$results = New-Object System.Collections.Generic.List[string]
$pass = 0; $fail = 0
function Check($name, $ok, $detail) {
  if ($ok) { $script:pass++; Write-Host "  PASS $name  $detail" -ForegroundColor Green } else { $script:fail++; Write-Host "  FAIL $name  $detail" -ForegroundColor Red }
  $results.Add(("{0} {1} {2}" -f ($(if ($ok) {'PASS'} else {'FAIL'})), $name, $detail))
}
function RectOf($h) { $r = [W3]::Vis($h); ,@($r.L, $r.T, ($r.R - $r.L), ($r.B - $r.T)) }
function RawOf($h) { $r = New-Object W3+RECT; [W3]::GetWindowRect($h, [ref]$r) | Out-Null; "$($r.L),$($r.T),$($r.R),$($r.B)" }

# ---- LayoutPlan (1–6 windows), independent re-implementation of LayoutPlan.swift for checking ----
# (PowerShell variable names are case-insensitive: $X and $x are the same variable)
function Integral($x, $y, $w, $h) { $x0 = [Math]::Floor($x); $y0 = [Math]::Floor($y); ,@($x0, $y0, ([Math]::Ceiling($x + $w) - $x0), ([Math]::Ceiling($y + $h) - $y0)) }
function Expected($n, $a) {
  $X, $Y, $Wd, $Ht = $a
  $out = @()
  switch ($n) {
    1 { $out += ,@($X, $Y, $Wd, $Ht) }
    { $_ -in 2, 3, 4 } { $w = $Wd / $n; for ($i = 0; $i -lt $n; $i++) { $out += ,(Integral ($X + $i * $w) $Y $w $Ht) } }
    5 { $h = $Ht / 2; foreach ($r in 0, 1) { $c = @(3, 2)[$r]; $w = $Wd / $c; for ($i = 0; $i -lt $c; $i++) { $out += ,(Integral ($X + $i * $w) ($Y + $r * $h) $w $h) } } }
    6 { $step = [Math]::Round(120 * [Math]::Max(1.0, $Ht / 1000.0), [MidpointRounding]::AwayFromZero); $w = $Wd / 4.0; $h = $Ht - 2 * $step
        $xs = @(@(0, (2 * $w)), @(($w / 2), (2.5 * $w)), @($w, (3 * $w)))
        for ($r = 0; $r -lt 3; $r++) { foreach ($ox in $xs[$r]) { $out += ,(Integral ($X + $ox) ($Y + $r * $step) $w $h) } } }
  }
  ,$out
}
# same tolerance as the arranger: origin exact (±2), size may be up to 25 pt smaller (character grid), never bigger
function Near($act, $exp, $pt) { $s = [int](25 * $pt); ([Math]::Abs($act[0] - $exp[0]) -le 2) -and ([Math]::Abs($act[1] - $exp[1]) -le 2) -and (($act[2] - $exp[2]) -le 2) -and (($act[2] - $exp[2]) -ge -$s) -and (($act[3] - $exp[3]) -le 2) -and (($act[3] - $exp[3]) -ge -$s) }
function Fmt($r) { "[{0},{1},{2},{3}]" -f $r[0], $r[1], $r[2], $r[3] }

# ---- snapshot of every other window (must be identical at the end) ----
$me = $PID
function Snapshot { $d = @{}; foreach ($h in [W3]::Top()) { if ([W3]::IsWindowVisible($h)) { $d[[long]$h] = (RawOf $h) + " min=" + [W3]::IsIconic($h) + " max=" + [W3]::IsZoomed($h) } }; $d }
$before = Snapshot

Write-Host '=== ShoWork42 W3 自動排版驗收 ===' -ForegroundColor Cyan
Write-Host '會開 6 個最小化的測試用 PowerShell 視窗，用不啟動的方式逐一還原讓 agent 自動排版，約 1 分鐘。其他視窗不會被動到。'
$tests = @()
for ($k = 1; $k -le 6; $k++) {
  $cpid = [W3]::Launch("conhost.exe powershell.exe -NoExit -NoProfile -Command `$host.UI.RawUI.WindowTitle='SW42-W3-$k'")
  $tests += @{ conhost = $cpid; hwnd = [IntPtr]::Zero; n = $k }
}
Start-Sleep 3
# a console window reports its CLIENT process (powershell), not conhost, as its owner
foreach ($t in $tests) {
  $pids = @($t.conhost) + @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($t.conhost)" | ForEach-Object { [int]$_.ProcessId })
  foreach ($h in [W3]::Top()) { $p = [uint32]0; [W3]::GetWindowThreadProcessId($h, [ref]$p) | Out-Null; if ($pids -contains [int]$p -and [W3]::Cls($h) -eq 'ConsoleWindowClass') { $t.hwnd = $h } }
}
$ok = @($tests | Where-Object { $_.hwnd -ne [IntPtr]::Zero }).Count -eq 6
Check '開了 6 個 conhost 測試視窗' $ok (($tests | ForEach-Object { "$($_.hwnd)" }) -join ',')
function CloseTests {
  foreach ($t in $tests) {
    Get-CimInstance Win32_Process -Filter "ParentProcessId=$($t.conhost)" | ForEach-Object { Stop-Process -Id $_.ProcessId -ErrorAction SilentlyContinue }
    Stop-Process -Id $t.conhost -ErrorAction SilentlyContinue
  }
}
if (-not $ok) { CloseTests; throw 'no test windows' }
foreach ($t in $tests) { if (-not [W3]::IsIconic($t.hwnd)) { [W3]::ShowWindow($t.hwnd, 7) | Out-Null } }   # make sure: minimised, no activation
Start-Sleep -Milliseconds 500
# the foreground window after the test windows exist: the arranger must never change it
$fgStart = [W3]::GetForegroundWindow()
# informational: a new conhost may take the foreground itself even when started minimised (not the arranger's doing)
Write-Host "  NOTE 開完測試視窗後的前景視窗=$fgStart（測試視窗：$(@($tests | Where-Object { $_.hwnd -eq $fgStart }).Count -gt 0)）"
$testSet = @{}; foreach ($t in $tests) { $testSet[[long]$t.hwnd] = $true }
$wids = ($tests | ForEach-Object { [long]$_.hwnd }) -join ','

# monitor of the test windows (all open on the same one); work area in physical pixels
$mon = [W3]::MonitorFromWindow($tests[0].hwnd, 2)
$mi = New-Object W3+MONITORINFO; $mi.cb = [Runtime.InteropServices.Marshal]::SizeOf($mi); [W3]::GetMonitorInfo($mon, [ref]$mi) | Out-Null
$dx = 0; $dy = 0; [W3]::GetDpiForMonitor($mon, 0, [ref]$dx, [ref]$dy) | Out-Null; $pt = $dx / 96.0
$work = @($mi.work.L, $mi.work.T, ($mi.work.R - $mi.work.L), ($mi.work.B - $mi.work.T))
Write-Host "  螢幕工作區 $(Fmt $work)（實際像素）DPI $dx"

$home42 = Join-Path $env:TEMP ("sw42-w3-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $home42 | Out-Null
$log = Join-Path $home42 'agent.log'
$started = @()                                                   # every agent this test started (and only those) is stopped at the end
function StartAgent($extra) {
  $psi = New-Object Diagnostics.ProcessStartInfo $Agent
  $psi.UseShellExecute = $false
  $psi.EnvironmentVariables['SHOWORK_PIPE'] = 'ShoWork42-w3test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
  $psi.EnvironmentVariables['SHOWORK_HOME'] = $home42
  $psi.EnvironmentVariables['SHOWORK_STATUS_FILE'] = (Join-Path $home42 'status.json')
  $psi.EnvironmentVariables['SHOWORK_DEBUG'] = '1'
  $psi.EnvironmentVariables['SHOWORK_ONLY_WIDS'] = $wids
  foreach ($k in $extra.Keys) { $psi.EnvironmentVariables[$k] = $extra[$k] }
  $p = [Diagnostics.Process]::Start($psi)
  $script:started += $p.Id
  Start-Sleep 2
  return $p
}
function Visible { @($tests | Where-Object { -not [W3]::IsIconic($_.hwnd) }) }
# wait until the visible test windows form the planned layout (any assignment of windows to frames)
function WaitLayout($n, $timeout = 6) {
  $exp = Expected $n $work
  $deadline = (Get-Date).AddSeconds($timeout)
  do {
    Start-Sleep -Milliseconds 300
    $acts = @(Visible | ForEach-Object { ,(RectOf $_.hwnd) })
    $used = @{}; $all = $true
    foreach ($e in $exp) {
      $hit = $false
      for ($i = 0; $i -lt $acts.Count; $i++) { if (-not $used[$i] -and (Near $acts[$i] $e $pt)) { $used[$i] = $true; $hit = $true; break } }
      if (-not $hit) { $all = $false; break }
    }
  } while (-not $all -and (Get-Date) -lt $deadline)
  $detail = "期望 " + (($exp | ForEach-Object { Fmt $_ }) -join ' ') + " 實際 " + (($acts | ForEach-Object { Fmt $_ }) -join ' ')
  return $all, $detail
}
function Show($t) { $script:fgRef = [W3]::GetForegroundWindow(); [W3]::ShowWindow($t.hwnd, 4) | Out-Null }          # SW_SHOWNOACTIVATE
function Hide($t) { $script:fgRef = [W3]::GetForegroundWindow(); [W3]::ShowWindow($t.hwnd, 7) | Out-Null }          # SW_SHOWMINNOACTIVE
# The arranger only ever touches the test windows, so the only window it could activate is one of them. Another
# program (e.g. a parallel test closing its own window) moving the foreground elsewhere is noted, not counted.
$fgRef = $fgStart
function Fg($label) {
  $f = [W3]::GetForegroundWindow()
  $ours = [bool]$testSet[[long]$f]
  $ok = ($f -eq $script:fgRef) -or -not $ours
  $note = if ($f -ne $script:fgRef -and -not $ours) { '（前景被其他程式換掉，不是測試視窗，不計）' } else { '' }
  Check "$label：前景沒有變成排過的測試視窗（排版不啟動視窗）" $ok "前景=$f 之前=$($script:fgRef)$note"
  $script:fgRef = $f
}

try {
  # ---------- A. auto arrange on count change ----------
  $proc = @(StartAgent @{ SHOWORK_AUTO_ARRANGE = '1'; SHOWORK_ARRANGE_ONLY_LISTED = '1' })[-1]
  Check 'agent 啟動（自己的 pipe、自己的資料夾）' (-not $proc.HasExited) "pid=$($proc.Id)"
  $steps = @(@{ show = @(0); n = 1 }, @{ show = @(1); n = 2 }, @{ show = @(2); n = 3 }, @{ show = @(3, 4, 5); n = 6 })
  foreach ($s in $steps) {
    foreach ($i in $s.show) { Show $tests[$i] }
    $ok, $d = WaitLayout $s.n
    Check "還原到 $($s.n) 個 → 自動排成 $($s.n) 個的版面" $ok $d
    Fg "$($s.n) 個"
  }
  # canonical stacking for 6: bottom row above middle row above top row (z-order among the test windows)
  $z = @([W3]::Top() | Where-Object { $testSet[[long]$_] })                       # top of z-order first
  $tops = $z | ForEach-Object { (RectOf $_)[1] }
  $sorted = @($tops | Sort-Object -Descending)
  Check '6 個：疊放順序 下排 > 中排 > 上排（標題列都露出）' ((@($tops) -join ',') -eq ($sorted -join ',')) ("由上而下的 y：" + (@($tops) -join ','))

  Hide $tests[2]
  $ok, $d = WaitLayout 5; Check '最小化 1 個 → 5 個（上 3 下 2）' $ok $d; Fg '5 個'

  # a maximised window: make the minimised one restore to maximised, then restore it without activation
  $wp = New-Object W3+WINDOWPLACEMENT; $wp.length = [Runtime.InteropServices.Marshal]::SizeOf($wp)
  [W3]::GetWindowPlacement($tests[2].hwnd, [ref]$wp) | Out-Null
  $wp.flags = $wp.flags -bor 2; $wp.showCmd = 7                                    # WPF_RESTORETOMAXIMIZED, stay minimised
  [W3]::SetWindowPlacement($tests[2].hwnd, [ref]$wp) | Out-Null
  Show $tests[2]
  $wasMax = [W3]::IsZoomed($tests[2].hwnd)
  $ok, $d = WaitLayout 6
  Check '還原成「最大化」的視窗也一起排（先還原、不啟動）' ($wasMax -and $ok -and -not [W3]::IsZoomed($tests[2].hwnd)) "還原時最大化=$wasMax 排完最大化=$([W3]::IsZoomed($tests[2].hwnd)) $d"
  Fg '最大化'

  Hide $tests[4]; Hide $tests[5]
  $ok, $d = WaitLayout 4; Check '最小化 2 個 → 4 個（四等分直欄）' $ok $d
  Fg '4 個'
  $cpu = $proc.TotalProcessorTime.TotalSeconds; Start-Sleep 10; $proc.Refresh()
  $idle = 100 * ($proc.TotalProcessorTime.TotalSeconds - $cpu) / 10 / [Environment]::ProcessorCount
  Check ("自動排版開著時閒置 CPU {0:N2}%（< 1%）" -f $idle) ($idle -lt 1) ''
  $ws = $proc.WorkingSet64 / 1MB
  Check ("agent working set {0:N1} MB（< 60 MB）" -f $ws) ($ws -lt 60) ("private {0:N1} MB" -f ($proc.PrivateMemorySize64 / 1MB))
  Stop-Process -Id $proc.Id

  # ---------- B. NOOP: plans and logs, moves nothing ----------
  $proc = @(StartAgent @{ SHOWORK_AUTO_ARRANGE = '1'; SHOWORK_ARRANGE_ONLY_LISTED = '1'; SHOWORK_ARRANGE_NOOP = '1' })[-1]
  $pre = @{}; foreach ($t in $tests) { $pre[[long]$t.hwnd] = RawOf $t.hwnd }
  Show $tests[4]; Start-Sleep 2.5
  $moved = @($tests | Where-Object { $_.n -ne 5 -and (RawOf $_.hwnd) -ne $pre[[long]$_.hwnd] }).Count
  $noop = (Get-Content $log -Raw -Encoding UTF8) -match 'ARRANGE NOOP: would arrange 5 windows'
  Check 'SHOWORK_ARRANGE_NOOP=1：只記錄計畫、一個視窗都不動' ($noop -and $moved -eq 0) "log=$noop 被動到=$moved"
  Stop-Process -Id $proc.Id

  # ---------- C. Mac semantics: ONLY_WIDS without ONLY_LISTED refuses when a foreign terminal is on screen ----------
  $foreign = @([W3]::Top() | Where-Object { -not $testSet[[long]$_] -and [W3]::IsWindowVisible($_) -and -not [W3]::IsIconic($_) -and ([W3]::Cls($_) -in 'ConsoleWindowClass', 'CASCADIA_HOSTING_WINDOW_CLASS') })
  if ($foreign.Count -gt 0) {
    $proc = @(StartAgent @{ SHOWORK_AUTO_ARRANGE = '1' })[-1]
    $pre = @{}; foreach ($t in $tests) { $pre[[long]$t.hwnd] = RawOf $t.hwnd }
    Hide $tests[4]; Start-Sleep 2.5
    $moved = @($tests | Where-Object { $_.n -ne 5 -and (RawOf $_.hwnd) -ne $pre[[long]$_.hwnd] }).Count
    $refused = (Get-Content $log -Raw -Encoding UTF8) -match 'ARRANGE REFUSED'
    Check "SHOWORK_ONLY_WIDS（不加 ONLY_LISTED）：畫面上有別的終端機視窗（$($foreign.Count) 個）→ 拒絕排版" ($refused -and $moved -eq 0) "log=$refused 被動到=$moved"
    Stop-Process -Id $proc.Id
  } else { Check '拒絕排版（畫面上沒有別的終端機視窗，略過）' $true 'skipped' }
  Fg '結束'
}
finally {
  CloseTests
  foreach ($id in $started) { Stop-Process -Id $id -ErrorAction SilentlyContinue }
}
Start-Sleep 1
# every window that existed before and still exists: same rect, same min/max state
$after = Snapshot
$changed = @($before.Keys | Where-Object { $after.ContainsKey($_) -and $after[$_] -ne $before[$_] } | ForEach-Object { "$_ [$([W3]::Cls([IntPtr]$_))] $($before[$_]) → $($after[$_])" })
Check "其他 $(@($before.Keys | Where-Object { $after.ContainsKey($_) }).Count) 個可見視窗位置／大小／狀態完全不變" ($changed.Count -eq 0) ($changed -join '; ')
$results.Add("TOTAL pass=$pass fail=$fail")
if (Test-Path $log) { $results.Add('--- agent.log (ARRANGE) ---'); Get-Content $log -Encoding UTF8 | Where-Object { $_ -match 'ARRANGE|AGENT' } | ForEach-Object { $results.Add($_) } }
$results | Out-File $Out -Encoding utf8
Write-Host "結果：$pass 通過、$fail 失敗（$Out）" -ForegroundColor Cyan
