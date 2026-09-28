# ShoWork42 Windows W0 驗收：光暈跟隨傳統主控台視窗
# 只動本腳本自己開的兩個測試視窗（白名單），不碰其他任何視窗。
# 用法（要在使用者桌面的互動工作階段執行）：powershell -File w0_e2e.ps1 -Agent <ShoWorkAgent.exe 路徑> -Out <結果檔> [-Direction inward|outward]
# -Direction：光暈方向（預設朝內）。朝內＝光暈剛好蓋住 A 的可見範圍、在 A 正上方、點擊穿透；朝外＝四邊等距框住 A、在 A 正下方。
# 測試 agent 用自己的資料夾（SHOWORK_HOME，裡面的 settings.json 指定方向）與自己的 pipe，不讀使用者的設定。
param([string]$Agent, [string]$Out, [ValidateSet('inward', 'outward')][string]$Direction = 'inward')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'guard.ps1')
$Host.UI.RawUI.WindowTitle = 'ShoWork42 W0 驗收（Claude Code）'
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class W {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint c);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, UIntPtr e);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int s);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint f);
  public static IntPtr RootAt(int x, int y) { POINT p; p.X = x; p.Y = y; return GetAncestor(WindowFromPoint(p), 2); }
  public static RECT Vis(IntPtr h) { RECT r; DwmGetWindowAttribute(h, 9, out r, 16); return r; }
  public static RECT Raw(IntPtr h) { RECT r; GetWindowRect(h, out r); return r; }
  // Alt tap lets a background process move the foreground (Windows' foreground lock)
  public static void Front(IntPtr h) { keybd_event(0x12,0,0,UIntPtr.Zero); keybd_event(0x12,0,2,UIntPtr.Zero); SetForegroundWindow(h); }
}
'@
# measure in physical pixels like the agent (DWM frame bounds are never DPI-virtualised; GetWindowRect is)
[W]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
$results = New-Object System.Collections.Generic.List[string]
$pass = 0; $fail = 0
function Check($name, $ok, $detail) {
  if ($ok) { $script:pass++; Write-Host "  PASS $name" -ForegroundColor Green } else { $script:fail++; Write-Host "  FAIL $name  $detail" -ForegroundColor Red }
  $results.Add(("{0} {1} {2}" -f ($(if ($ok) {'PASS'} else {'FAIL'})), $name, $detail))
}
function OpenConsole($title) {
  $p = Start-Process conhost.exe -ArgumentList "powershell.exe -NoExit -NoProfile -Command `"`$host.UI.RawUI.WindowTitle='$title'`"" -PassThru
  Start-Sleep 2
  $ps = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($p.Id) AND Name='powershell.exe'"
  $f = [IO.Path]::GetTempFileName()
  & $Agent --console-hwnd $ps.ProcessId $f | Out-Null
  Start-Sleep 1
  $h = [IntPtr][long](Get-Content $f); Remove-Item $f
  return @{ conhost = $p; ps = $ps.ProcessId; hwnd = $h }
}
Write-Host '=== ShoWork42 W0 驗收 ===' -ForegroundColor Cyan
Write-Host '會開兩個測試用 PowerShell 視窗，自動移動／切換／縮小它們，約 1 分鐘。其他視窗不會被動到。'
$a = OpenConsole 'SW42-TEST-A'
$b = OpenConsole 'SW42-TEST-B'
Check 'console-hwnd A（AttachConsole→GetConsoleWindow）' ($a.hwnd -ne [IntPtr]::Zero) "hwnd=$($a.hwnd)"
Check 'console-hwnd B' ($b.hwnd -ne [IntPtr]::Zero -and $b.hwnd -ne $a.hwnd) "hwnd=$($b.hwnd)"

[W]::SetWindowPos($a.hwnd, [IntPtr]::Zero, 200, 150, 900, 520, 0x14) | Out-Null
[W]::SetWindowPos($b.hwnd, [IntPtr]::Zero, 500, 300, 900, 520, 0x14) | Out-Null
$env:SHOWORK_DEBUG = "1"
$home0 = Join-Path ([IO.Path]::GetTempPath()) ('sw42-w0-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $home0 | Out-Null
[IO.File]::WriteAllText("$home0\settings.json", '{"v":1,"general":{"direction":"' + $Direction + '"}}')
$env:SHOWORK_HOME = $home0
$env:SHOWORK_PIPE = 'sw42-w0-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$env:SHOWORK_STATUS_FILE = "$home0\status.json"
Write-Host "光暈方向：$Direction"
$agentProc = Start-Process $Agent -ArgumentList "--glow $($a.hwnd) working 120" -PassThru
Start-Sleep 2
# find the glow: the agent process's visible top-level windows (outward breathing: one; inward: four strips inside the edge)
Add-Type @'
using System; using System.Runtime.InteropServices; using System.Collections.Generic;
public static class E {
  public delegate bool CB(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(CB cb, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  public static List<IntPtr> All(uint pid) { var f = new List<IntPtr>(); EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (p == pid && IsWindowVisible(h)) f.Add(h); return true; }, IntPtr.Zero); return f; }
}
'@
function Glows { , [E]::All([uint32]$agentProc.Id) }
$inward = $Direction -eq 'inward'
$where = $(if ($inward) { '正上方' } else { '正下方' })
function Aligned($target) {
  $g = Glows; if ($g.Count -eq 0) { return $false, 'no glow window' }
  $t = [W]::Vis($target)
  # (PowerShell names are case-insensitive: gT, not T next to t)
  $gL = ($g | ForEach-Object { [W]::Raw($_).L } | Measure-Object -Minimum).Minimum; $gT = ($g | ForEach-Object { [W]::Raw($_).T } | Measure-Object -Minimum).Minimum
  $gR = ($g | ForEach-Object { [W]::Raw($_).R } | Measure-Object -Maximum).Maximum; $gB = ($g | ForEach-Object { [W]::Raw($_).B } | Measure-Object -Maximum).Maximum
  $padL = $t.L - $gL; $padT = $t.T - $gT; $padR = $gR - $t.R; $padB = $gB - $t.B
  if ($inward) { $ok = [Math]::Abs($padL) -le 1 -and [Math]::Abs($padT) -le 1 -and [Math]::Abs($padR) -le 1 -and [Math]::Abs($padB) -le 1 }
  else { $ok = ($padL -gt 0) -and ($padL -eq $padT) -and ($padL -eq $padR) -and ($padL -eq $padB) }
  return $ok, "pad L/T/R/B=$padL/$padT/$padR/$padB parts=$($g.Count)"
}
function Stacked($target) {
  # outward: the first VISIBLE windows under the target are the glow (invisible IME helpers sit in between);
  # inward: the first visible windows ABOVE the target are the glow strips
  $g = Glows; if ($g.Count -eq 0) { return $false }
  $cmd = $(if ($inward) { 3 } else { 2 })
  $h = $target
  for ($k = 0; $k -lt $g.Count; $k++) {
    $h = [W]::GetWindow($h, $cmd); $n = 0
    while ($h -ne [IntPtr]::Zero -and -not [W]::IsWindowVisible($h) -and $n -lt 64) { $h = [W]::GetWindow($h, $cmd); $n++ }
    if ($g -notcontains $h) { return $false }
  }
  return $true
}
function ClickThrough($target) {
  # points inside the glow band hit the target itself (the glow is click-through); left/top/bottom-left, where B never overlaps A
  $t = [W]::Vis($target)
  $pts = @(@(($t.L + 4), [int](($t.T + $t.B) / 2)), @(($t.L + 60), ($t.T + 4)), @(($t.L + 12), ($t.B - 5)))
  $hits = $pts | ForEach-Object { [W]::RootAt($_[0], $_[1]) }
  return (@($hits | Where-Object { $_ -ne $target }).Count -eq 0), ("hits=" + ($hits -join ','))
}

$ok, $d = Aligned $a.hwnd; Check $(if ($inward) { '初始：光暈剛好蓋住 A 的可見範圍' } else { '初始：光暈四邊等距框住 A' }) $ok $d
Check "初始：光暈在 A $where（疊放）" (Stacked $a.hwnd) ''
if ($inward) { $ok, $d = ClickThrough $a.hwnd; Check '初始：光暈範圍內點擊穿透到 A（WindowFromPoint）' $ok $d }

$moves = @(@(100,100,800,500), @(700,200,1000,600), @(300,400,600,400), @(50,50,1200,700), @(400,250,900,520))
$i = 0
foreach ($m in $moves) {
  $i++
  [W]::SetWindowPos($a.hwnd, [IntPtr]::Zero, $m[0], $m[1], $m[2], $m[3], 0x14) | Out-Null
  Start-Sleep -Milliseconds 400
  $ok, $d = Aligned $a.hwnd; Check "移動／縮放 $i 跟上" $ok $d
}
for ($k = 1; $k -le 4; $k++) {
  [W]::Front($b.hwnd); Start-Sleep -Milliseconds 500
  Check "B 到前面 $k：光暈仍在 A $where" (Stacked $a.hwnd) ''
  [W]::Front($a.hwnd); Start-Sleep -Milliseconds 500
  Check "A 到前面 $k：光暈仍在 A $where" (Stacked $a.hwnd) ''
}
[W]::ShowWindow($a.hwnd, 6) | Out-Null; Start-Sleep -Milliseconds 600      # minimise
Check '最小化：光暈隱藏' ((Glows).Count -eq 0) ''
[W]::ShowWindow($a.hwnd, 9) | Out-Null; Start-Sleep -Milliseconds 800      # restore
$ok, $d = Aligned $a.hwnd; Check '還原：光暈回來且對齊' $ok $d
Check "還原：光暈在 A $where" (Stacked $a.hwnd) ''
if ($inward) { $ok, $d = ClickThrough $a.hwnd; Check '還原：點擊穿透到 A' $ok $d }

Write-Host ''
Write-Host $(if ($inward) { "請看一下螢幕：A 視窗的邊緣應該有往內的紫色呼吸光。10 秒後自動收尾。" } else { "請看一下螢幕：A 視窗外圍應該有紫色呼吸光。10 秒後自動收尾。" }) -ForegroundColor Yellow
Start-Sleep 10
$cpu = (Get-Process -Id $agentProc.Id).TotalProcessorTime.TotalSeconds
$uptime = ((Get-Date) - (Get-Process -Id $agentProc.Id).StartTime).TotalSeconds
Check ("agent CPU {0:N2}% 平均（< 1%）" -f (100 * $cpu / $uptime / [Environment]::ProcessorCount)) ((100 * $cpu / $uptime / [Environment]::ProcessorCount) -lt 1) ''
Check ("agent 記憶體 {0:N0} MB（< 60MB）" -f ((Get-Process -Id $agentProc.Id).WorkingSet64/1MB)) (((Get-Process -Id $agentProc.Id).WorkingSet64/1MB) -lt 60) ''

Stop-Process -Id $agentProc.Id -ErrorAction SilentlyContinue
foreach ($c in @($a, $b)) { Stop-Process -Id $c.ps -ErrorAction SilentlyContinue; Stop-Process -Id $c.conhost.Id -ErrorAction SilentlyContinue }
Remove-Item -Recurse -Force $home0 -ErrorAction SilentlyContinue
$results.Add("DIRECTION $Direction")
$results.Add("TOTAL pass=$pass fail=$fail")
$results.Add('CLAUDE_DONE')
$results | Out-File $Out -Encoding utf8
Write-Host "結果：$pass 通過、$fail 失敗" -ForegroundColor Cyan
Start-Sleep 5
