# ShoWork42 Windows W0 驗收：光暈跟隨傳統主控台視窗
# 只動本腳本自己開的兩個測試視窗（白名單），不碰其他任何視窗。
# 用法（要在使用者桌面的互動工作階段執行）：powershell -File w0_e2e.ps1 <ShoWorkAgent.exe 路徑> <結果檔>
param([string]$Agent, [string]$Out)
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
$agentProc = Start-Process $Agent -ArgumentList "--glow $($a.hwnd) working 120" -PassThru
Start-Sleep 2
# find the glow: the agent process's visible top-level window
Add-Type @'
using System; using System.Runtime.InteropServices; using System.Collections.Generic;
public static class E {
  public delegate bool CB(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(CB cb, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  public static IntPtr Of(uint pid) { IntPtr f = IntPtr.Zero; EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (p == pid && IsWindowVisible(h)) { f = h; return false; } return true; }, IntPtr.Zero); return f; }
}
'@
function Glow { [E]::Of([uint32]$agentProc.Id) }
function Aligned($target) {
  $g = Glow; if ($g -eq [IntPtr]::Zero) { return $false, 'no glow window' }
  $t = [W]::Vis($target); $r = [W]::Raw($g)
  $padL = $t.L - $r.L; $padT = $t.T - $r.T; $padR = $r.R - $t.R; $padB = $r.B - $t.B
  $ok = ($padL -gt 0) -and ($padL -eq $padT) -and ($padL -eq $padR) -and ($padL -eq $padB)
  return $ok, "pad L/T/R/B=$padL/$padT/$padR/$padB"
}
function Below($target) {
  # first VISIBLE window under the target must be the glow (invisible IME helpers sit in between)
  $h = [W]::GetWindow($target, 2); $n = 0
  while ($h -ne [IntPtr]::Zero -and -not [W]::IsWindowVisible($h) -and $n -lt 64) { $h = [W]::GetWindow($h, 2); $n++ }
  return $h -eq (Glow)
}

$ok, $d = Aligned $a.hwnd; Check '初始：光暈四邊等距框住 A' $ok $d
Check '初始：光暈在 A 正下方（疊放）' (Below $a.hwnd) ''

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
  Check "B 到前面 $k：光暈仍在 A 正下方" (Below $a.hwnd) ''
  [W]::Front($a.hwnd); Start-Sleep -Milliseconds 500
  Check "A 到前面 $k：光暈仍在 A 正下方" (Below $a.hwnd) ''
}
[W]::ShowWindow($a.hwnd, 6) | Out-Null; Start-Sleep -Milliseconds 600      # minimise
Check '最小化：光暈隱藏' (-not [W]::IsWindowVisible((Glow))) ''
[W]::ShowWindow($a.hwnd, 9) | Out-Null; Start-Sleep -Milliseconds 800      # restore
$ok, $d = Aligned $a.hwnd; Check '還原：光暈回來且對齊' $ok $d

Write-Host ''
Write-Host "請看一下螢幕：A 視窗外圍應該有紫色呼吸光。10 秒後自動收尾。" -ForegroundColor Yellow
Start-Sleep 10
$cpu = (Get-Process -Id $agentProc.Id).TotalProcessorTime.TotalSeconds
$uptime = ((Get-Date) - (Get-Process -Id $agentProc.Id).StartTime).TotalSeconds
Check ("agent CPU {0:N2}% 平均（< 1%）" -f (100 * $cpu / $uptime / [Environment]::ProcessorCount)) ((100 * $cpu / $uptime / [Environment]::ProcessorCount) -lt 1) ''
Check ("agent 記憶體 {0:N0} MB（< 60MB）" -f ((Get-Process -Id $agentProc.Id).WorkingSet64/1MB)) (((Get-Process -Id $agentProc.Id).WorkingSet64/1MB) -lt 60) ''

Stop-Process -Id $agentProc.Id -ErrorAction SilentlyContinue
foreach ($c in @($a, $b)) { Stop-Process -Id $c.ps -ErrorAction SilentlyContinue; Stop-Process -Id $c.conhost.Id -ErrorAction SilentlyContinue }
$results.Add("TOTAL pass=$pass fail=$fail")
$results.Add('CLAUDE_DONE')
$results | Out-File $Out -Encoding utf8
Write-Host "結果：$pass 通過、$fail 失敗" -ForegroundColor Cyan
Start-Sleep 5
