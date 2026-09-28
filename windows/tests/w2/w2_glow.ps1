# ShoWork42 W2: every glow style on a real window - CPU, memory, alignment, z-order, screenshots.
# Touches ONLY the two console windows this script opens (whitelist); every other visible window's rect is
# compared before/after. Screenshots are taken only when every sample point of the rect is one of our windows.
# Usage (interactive desktop): powershell -File w2_glow.ps1 -Agent <ShoWorkAgent.exe> -Work <temp dir> [-Seconds 10]
param([string]$Agent, [string]$Work, [int]$Seconds = 10, [string]$Styles = 'breathe,orbit,ripple,drift,sparkle,aurora', [double]$Width = 1)
$ErrorActionPreference = 'Stop'
Add-Type -Path "$PSScriptRoot\Win.cs" -ReferencedAssemblies System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class Dpi { [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c); }
'@
[Dpi]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
New-Item -ItemType Directory -Force $Work | Out-Null
$pass = 0; $fail = 0
function Check($name, $ok, $detail) {
  if ($ok) { $script:pass++; Write-Host "  PASS $name $detail" } else { $script:fail++; Write-Host "  FAIL $name $detail" }
}
$testPids = New-Object System.Collections.Generic.List[uint32]
function OpenConsole($title) {
  $p = Start-Process conhost.exe -ArgumentList "powershell.exe -NoExit -NoProfile -Command `"`$host.UI.RawUI.WindowTitle='$title'`"" -PassThru
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

$results = @()
foreach ($style in $Styles.Split(',')) {
  $home2 = Join-Path $Work "home-$style"
  New-Item -ItemType Directory -Force $home2 | Out-Null
  $j = '{"v":1,"looks":{"working":{"enabled":true,"hex":"#9E66FF","style":"' + $style + '","width":' + $Width + '}}}'
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
  Check "$style aligned" ((($tv.L - $gL) -gt 0) -and ($tv.L - $gL -eq $tv.T - $gT) -and ($tv.L - $gL -eq $gR - $tv.R) -and ($tv.L - $gL -eq $gB - $tv.B)) "pads=$pads parts=$($glows.Count)"
  # z-order: the first visible windows below the target are our strips
  $h = $tgt.hwnd; $okBelow = $true
  for ($k = 0; $k -lt $glows.Count; $k++) {
    $h = [W2]::GetWindow($h, 2); $n = 0
    while ($h -ne [IntPtr]::Zero -and -not [W2]::IsWindowVisible($h) -and $n -lt 64) { $h = [W2]::GetWindow($h, 2); $n++ }
    if ($glows -notcontains $h) { $okBelow = $false }
  }
  Check "$style below target" $okBelow ''
  # CPU over $Seconds while visible and animating
  $ag.Refresh(); $c0 = $ag.TotalProcessorTime.TotalMilliseconds; $w0 = [Diagnostics.Stopwatch]::StartNew()
  Start-Sleep $Seconds
  $ag.Refresh(); $cpuMs = $ag.TotalProcessorTime.TotalMilliseconds - $c0; $wall = $w0.Elapsed.TotalMilliseconds
  $core = 100 * $cpuMs / $wall; $all = $core / [Environment]::ProcessorCount
  $ws = $ag.WorkingSet64 / 1MB; $priv = $ag.PrivateMemorySize64 / 1MB
  $shot = ''
  $rect = New-Object W2+RECT; $rect.L = $gL; $rect.T = $gT; $rect.R = $gR; $rect.B = $gB
  if ([W2]::OnlyMine($rect, @($tgt.hwnd, $back.hwnd))) { $shot = Join-Path $Work "glow-$style.png"; [W2]::Capture($rect, $shot) } else { $shot = '(skipped: rect not fully ours)' }
  # minimise our target (no activation) -> glow hides; restore without activating
  [Dpi]::ShowWindow($tgt.hwnd, 7) | Out-Null; Start-Sleep -Milliseconds 700      # SW_SHOWMINNOACTIVE
  $hidden = @([W2]::Of([uint32]$ag.Id)).Count -eq 0
  $ag.Refresh(); $wsHidden = $ag.WorkingSet64 / 1MB
  [Dpi]::ShowWindow($tgt.hwnd, 4) | Out-Null; Start-Sleep -Milliseconds 900      # SW_SHOWNOACTIVATE
  $back2 = @([W2]::Of([uint32]$ag.Id)).Count -gt 0
  Check "$style hides when minimised, returns after" ($hidden -and $back2) ''
  $line = "{0,-8} CPU {1,5:N2}% of one core = {2,5:N2}% total ({3} cores)  WS {4,5:N1} MB  private {5,5:N1} MB  (minimised: WS {6:N1} MB)  {7}" -f $style, $core, $all, [Environment]::ProcessorCount, $ws, $priv, $wsHidden, $shot
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
$results | Out-File (Join-Path $Work 'w2_glow_result.txt') -Encoding utf8
Write-Host "TOTAL pass=$pass fail=$fail"
