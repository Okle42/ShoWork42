# ShoWork42 W2: every glow style on a real window - CPU, memory, alignment, z-order, screenshots.
# Touches ONLY the two console windows this script opens (whitelist); every other visible window's rect is
# compared before/after. Screenshots are taken only when every sample point of the rect is one of our windows.
# Usage (interactive desktop): powershell -File w2_glow.ps1 -Agent <ShoWorkAgent.exe> -Work <temp dir> [-Seconds 10] [-Direction inward|outward]
# -Direction (settings.json general.direction; default inward): inward = the glow covers exactly the target's visible rect and
# sits directly ABOVE it, click-through; outward = the glow frames the target with the same pad on every side, directly below it.
param([string]$Agent, [string]$Work, [int]$Seconds = 10, [string]$Styles = 'breathe,orbit,ripple,drift,sparkle,aurora', [double]$Width = 1,
      [ValidateSet('inward', 'outward')][string]$Direction = 'inward')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\guard.ps1')
Add-Type -Path "$PSScriptRoot\Win.cs" -ReferencedAssemblies System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class Dpi { [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] static extern void keybd_event(byte k, byte s, uint f, UIntPtr e);
  // Alt tap lets a background process move the foreground (Windows' foreground lock), as in w0_e2e.ps1.
  // The caller only does this while one of ITS test windows is the foreground (the Alt goes there).
  // Run from a hidden shell that trick is not enough: then join the input queue of the (test) foreground window's thread.
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
  [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool on);
  [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
  public static bool Front(IntPtr h) {
    keybd_event(0x12,0,0,UIntPtr.Zero); keybd_event(0x12,0,2,UIntPtr.Zero); SetForegroundWindow(h);
    for (int i = 0; i < 20 && GetForegroundWindow() != h; i++) System.Threading.Thread.Sleep(5);
    if (GetForegroundWindow() == h) return true;
    uint me = GetCurrentThreadId(), fg = GetWindowThreadProcessId(GetForegroundWindow(), IntPtr.Zero);
    if (fg != 0 && fg != me && AttachThreadInput(me, fg, true)) { SetForegroundWindow(h); AttachThreadInput(me, fg, false); }
    for (int i = 0; i < 20 && GetForegroundWindow() != h; i++) System.Threading.Thread.Sleep(5);
    return GetForegroundWindow() == h; } }
'@
[Dpi]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
New-Item -ItemType Directory -Force $Work | Out-Null
$pass = 0; $fail = 0
function Check($name, $ok, $detail) {
  if ($ok) { $script:pass++; Write-Host "  PASS $name $detail" } else { $script:fail++; Write-Host "  FAIL $name $detail" }
}
$testPids = New-Object System.Collections.Generic.List[uint32]
function OpenConsole($title) {
  # the window fills with text up to its edges, so the screenshots show whether text under the glow stays readable
  $cmd = "`$host.UI.RawUI.WindowTitle='$title'; 1..60 | ForEach-Object { 'Line {0:D2}  The quick brown fox jumps over the lazy dog 0123456789 ~!@#%^&*() [ok] claude> done' -f `$_ }"
  $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
  $p = Start-Process conhost.exe -ArgumentList "powershell.exe -NoExit -NoProfile -EncodedCommand $enc" -PassThru
  Start-Sleep 2
  $ps = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($p.Id) AND Name='powershell.exe'"
  $f = [IO.Path]::GetTempFileName()
  & $Agent --console-hwnd $ps.ProcessId $f | Out-Null
  Start-Sleep 1
  $h = [IntPtr][long](Get-Content $f); Remove-Item $f
  $testPids.Add([uint32]$p.Id); $testPids.Add([uint32]$ps.ProcessId)
  return @{ conhost = $p; ps = $ps.ProcessId; hwnd = $h }
}

$before = [W2]::AllRects(@())
$back = OpenConsole 'SW42-W2-BACK'
$tgt = OpenConsole 'SW42-W2-TARGET'
[W2]::SetWindowPos($back.hwnd, [IntPtr]::Zero, 60, 60, 1300, 800, 0x14) | Out-Null      # NOZORDER|NOACTIVATE
[W2]::SetWindowPos($tgt.hwnd, [IntPtr]::Zero, 260, 220, 900, 480, 0x14) | Out-Null
Start-Sleep 1

# are the first visible windows above (cmd 3 = GW_HWNDPREV) / below (2 = GW_HWNDNEXT) the target our glow windows?
function Stacked($glows, $cmd) {
  $h = $tgt.hwnd
  for ($k = 0; $k -lt $glows.Count; $k++) {
    $h = [W2]::GetWindow($h, $cmd); $n = 0
    while ($h -ne [IntPtr]::Zero -and -not [W2]::IsWindowVisible($h) -and $n -lt 64) { $h = [W2]::GetWindow($h, $cmd); $n++ }
    if ($glows -notcontains $h) { return $false }
  }
  return $true
}
# ms until the glow is directly above the target again (polled every 10 ms; -1 = not within 1.5 s, or lost again within 300 ms)
function Restack($glows) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.ElapsedMilliseconds -lt 1500) {
    if (Stacked $glows 3) { $ms = $sw.ElapsedMilliseconds; Start-Sleep -Milliseconds 300; if (Stacked $glows 3) { return $ms } else { return -1 } }
    Start-Sleep -Milliseconds 10
  }
  return -1
}

$results = @()
foreach ($style in $Styles.Split(',')) {
  $home2 = Join-Path $Work "home-$style"
  New-Item -ItemType Directory -Force $home2 | Out-Null
  $j = '{"v":1,"looks":{"working":{"enabled":true,"hex":"#9E66FF","style":"' + $style + '","width":' + $Width + '}},"general":{"direction":"' + $Direction + '"}}'
  [IO.File]::WriteAllText("$home2\settings.json", $j)
  $env:SHOWORK_HOME = $home2; $env:SHOWORK_DEBUG = '1'
  $env:SHOWORK_PIPE = 'sw42-w2-glow-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
  $ag = Start-Process $Agent -ArgumentList "--glow $($tgt.hwnd) working $($Seconds + 30)" -PassThru
  Start-Sleep 3
  $glows = [W2]::Of([uint32]$ag.Id)
  # alignment: the strips together frame the target with the same pad on every side
  $tv = [W2]::Vis($tgt.hwnd)     # (PowerShell names are case-insensitive: not $t next to $T)
  $gL = ($glows | ForEach-Object { [W2]::Rect($_).L } | Measure-Object -Minimum).Minimum
  $gT = ($glows | ForEach-Object { [W2]::Rect($_).T } | Measure-Object -Minimum).Minimum
  $gR = ($glows | ForEach-Object { [W2]::Rect($_).R } | Measure-Object -Maximum).Maximum
  $gB = ($glows | ForEach-Object { [W2]::Rect($_).B } | Measure-Object -Maximum).Maximum
  $pads = "$($tv.L - $gL)/$($tv.T - $gT)/$($gR - $tv.R)/$($gB - $tv.B)"
  if ($Direction -eq 'outward') {
    Check "$style aligned" ((($tv.L - $gL) -gt 0) -and ($tv.L - $gL -eq $tv.T - $gT) -and ($tv.L - $gL -eq $gR - $tv.R) -and ($tv.L - $gL -eq $gB - $tv.B)) "pads=$pads parts=$($glows.Count)"
    Check "$style below target" (Stacked $glows 2) ''
  } else {
    # inward: the strips together cover exactly the target's visible rect (the edge of the light is the window's edge)
    Check "$style covers the target rect" (($glows.Count -ge 1) -and [Math]::Abs($tv.L - $gL) -le 1 -and [Math]::Abs($tv.T - $gT) -le 1 -and [Math]::Abs($gR - $tv.R) -le 1 -and [Math]::Abs($gB - $tv.B) -le 1) "diff L/T/R/B=$pads parts=$($glows.Count)"
    Check "$style directly above target" (Stacked $glows 3) ''
    # click-through: points inside the glow band (left edge, top edge, near the bottom-right corner) hit the target
    $hits = @(@(($tv.L + 4), [int](($tv.T + $tv.B) / 2)), @([int](($tv.L + $tv.R) / 2), ($tv.T + 4)), @(($tv.R - 6), ($tv.B - 12))) | ForEach-Object {
      $pt = New-Object W2+POINT; $pt.X = $_[0]; $pt.Y = $_[1]; [W2]::GetAncestor([W2]::WindowFromPoint($pt), 2) }
    Check "$style click-through (WindowFromPoint in the band = target)" (@($hits | Where-Object { $_ -ne $tgt.hwnd }).Count -eq 0) ("hits=" + ($hits -join ','))
    # activation: another test window to the front and back; the glow must be right above the target again quickly
    $fg = [Dpi]::GetForegroundWindow()
    if (@($tgt.hwnd, $back.hwnd) -contains $fg) {
      $okB = [Dpi]::Front($back.hwnd); $msB = Restack $glows
      $okT = [Dpi]::Front($tgt.hwnd); $msT = Restack $glows
      Check "$style stays above after activating BACK then TARGET" ($okB -and $okT -and $msB -ge 0 -and $msT -ge 0) "fg ok=$okB/$okT restacked after ${msB} ms / ${msT} ms"
    } else { Write-Host "  SKIP $style activation (the foreground is not one of the test windows; not sending Alt to someone else's window)" }
  }
  # CPU over $Seconds while visible and animating
  $ag.Refresh(); $c0 = $ag.TotalProcessorTime.TotalMilliseconds; $w0 = [Diagnostics.Stopwatch]::StartNew()
  Start-Sleep $Seconds
  $ag.Refresh(); $cpuMs = $ag.TotalProcessorTime.TotalMilliseconds - $c0; $wall = $w0.Elapsed.TotalMilliseconds
  $core = 100 * $cpuMs / $wall; $all = $core / [Environment]::ProcessorCount
  $ws = $ag.WorkingSet64 / 1MB; $priv = $ag.PrivateMemorySize64 / 1MB
  $shot = ''
  $rect = New-Object W2+RECT; $rect.L = $gL; $rect.T = $gT; $rect.R = $gR; $rect.B = $gB
  if ($Direction -eq 'inward') { $rect.L -= 24; $rect.T -= 24; $rect.R += 24; $rect.B += 24 }     # a little of the BACK window around it: the edge shows
  if ([W2]::OnlyMine($rect, @($tgt.hwnd, $back.hwnd))) { $shot = Join-Path $Work "glow-$Direction-$style.png"; [W2]::Capture($rect, $shot) } else { $shot = '(skipped: rect not fully ours)' }
  # minimise our target (no activation) -> glow hides; restore without activating
  [Dpi]::ShowWindow($tgt.hwnd, 7) | Out-Null; Start-Sleep -Milliseconds 700      # SW_SHOWMINNOACTIVE
  $hidden = @([W2]::Of([uint32]$ag.Id)).Count -eq 0
  $ag.Refresh(); $wsHidden = $ag.WorkingSet64 / 1MB
  [Dpi]::ShowWindow($tgt.hwnd, 4) | Out-Null; Start-Sleep -Milliseconds 900      # SW_SHOWNOACTIVATE
  $back2 = @([W2]::Of([uint32]$ag.Id)).Count -gt 0
  Check "$style hides when minimised, returns after" ($hidden -and $back2) ''
  $line = "{0,-8} {8,-7} CPU {1,5:N2}% of one core = {2,5:N2}% total ({3} cores)  WS {4,5:N1} MB  private {5,5:N1} MB  (minimised: WS {6:N1} MB)  {7}" -f $style, $core, $all, [Environment]::ProcessorCount, $ws, $priv, $wsHidden, $shot, $Direction
  Write-Host $line; $results += $line
  Stop-Process -Id $ag.Id
  Start-Sleep -Milliseconds 500
}

foreach ($c in @($back, $tgt)) { Stop-Process -Id $c.ps -ErrorAction SilentlyContinue; Stop-Process -Id $c.conhost.Id -ErrorAction SilentlyContinue }
Start-Sleep 1
$after = [W2]::AllRects(@())
$gone = $before | Where-Object { $after -notcontains $_ }
# a window that closed on its own is not "moved"; only same hwnd with a different rect counts
$moved = $gone | Where-Object { $hw = $_.Split(':')[0]; $after | Where-Object { $_.Split(':')[0] -eq $hw } }
Check 'other windows untouched' (@($moved).Count -eq 0) ("moved: " + ($moved -join ' '))
$results | Out-File (Join-Path $Work "w2_glow_result_$Direction.txt") -Encoding utf8
Write-Host "TOTAL pass=$pass fail=$fail"
