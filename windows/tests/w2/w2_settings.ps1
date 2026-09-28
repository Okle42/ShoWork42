# ShoWork42 W2 驗收：設定視窗（UI Automation 操作）→ 光暈即時套用、關掉的狀態改亮下一個、settings.json 來回。
# 只動本腳本自己開的主控台視窗與自己的 agent（獨立 pipe／資料夾）；其他視窗前後比對位置。
# 不碰「開機時啟動」（會寫使用者的 HKCU Run），只檢查它顯示的跟登錄檔一致。
# 用法：powershell -File w2_settings.ps1 -Agent <ShoWorkAgent.exe> -Work <暫存資料夾>
param([string]$Agent, [string]$Work)
$ErrorActionPreference = 'Stop'
Add-Type -Path "$PSScriptRoot\Win.cs" -ReferencedAssemblies System.Drawing
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class Dpi { [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v); }
'@
[Dpi]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $Work | Out-Null
$pass = 0; $fail = 0
function Check($name, $ok, $detail) {
  if ($ok) { $script:pass++; Write-Host "  PASS $name $detail" } else { $script:fail++; Write-Host "  FAIL $name $detail" }
}
$A = [System.Windows.Automation.AutomationElement]
$TP = [System.Windows.Automation.TreeScope]
function Find($root, $name) {
  $c = New-Object System.Windows.Automation.PropertyCondition($A::NameProperty, $name)
  for ($i = 0; $i -lt 20; $i++) { $e = $root.FindFirst($TP::Descendants, $c); if ($e) { return $e }; Start-Sleep -Milliseconds 250 }
  throw "UIA: '$name' not found"
}
function FindT($root, $name, $type) {
  $c = New-Object System.Windows.Automation.AndCondition((New-Object System.Windows.Automation.PropertyCondition($A::NameProperty, $name)), (New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, $type)))
  for ($i = 0; $i -lt 20; $i++) { $e = $root.FindFirst($TP::Descendants, $c); if ($e) { return $e }; Start-Sleep -Milliseconds 250 }
  throw "UIA: '$name' ($($type.ProgrammaticName)) not found"
}
function Toggle($root, $name) { (Find $root $name).GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle() }
function ToggleState($root, $name) { (Find $root $name).GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState.ToString() }
# WinForms TrackBar has no RangeValue pattern: arrow keys sent to OUR slider's window (it reports WM_HSCROLL to the form)
function SetRange($root, $name, $v) {
  $h = [IntPtr](FindT $root $name ([System.Windows.Automation.ControlType]::Slider)).Current.NativeWindowHandle
  $now = [int][W2]::SendMessage($h, 0x400, [IntPtr]::Zero, [IntPtr]::Zero)          # TBM_GETPOS
  $key = $(if ($v -gt $now) { 0x27 } else { 0x25 })                                  # VK_RIGHT / VK_LEFT
  for ($i = 0; $i -lt [Math]::Abs($v - $now); $i++) { [W2]::SendMessage($h, 0x100, [IntPtr]$key, [IntPtr]::Zero) | Out-Null; [W2]::SendMessage($h, 0x101, [IntPtr]$key, [IntPtr]::Zero) | Out-Null }
}
function GetRange($root, $name) { [int][W2]::SendMessage([IntPtr](FindT $root $name ([System.Windows.Automation.ControlType]::Slider)).Current.NativeWindowHandle, 0x400, [IntPtr]::Zero, [IntPtr]::Zero) }
function Pick($root, $combo, $item) {
  $c = FindT $root $combo ([System.Windows.Automation.ControlType]::ComboBox)
  $c.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand(); Start-Sleep -Milliseconds 300
  (Find $c $item).GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select(); Start-Sleep -Milliseconds 200
  $c.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Collapse()
}
function Page($root, $name) { (Find $root $name).GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select(); Start-Sleep -Milliseconds 400 }
function Status { try { Get-Content "$Work\status.json" -Raw | ConvertFrom-Json } catch { $null } }
function GlowState { $s = Status; if ($s -and $s.glows) { ($s.glows | Select-Object -First 1).state } else { 'none' } }
function Settings { Get-Content "$Work\settings.json" -Raw | ConvertFrom-Json }
function Send($ev, $procId) {
  $p = New-Object System.IO.Pipes.NamedPipeClientStream('.', $env:SHOWORK_PIPE, [System.IO.Pipes.PipeDirection]::Out)
  $p.Connect(2000)
  $b = [Text.Encoding]::UTF8.GetBytes('{"v":1,"event":"' + $ev + '","agent":"claude","pid":' + $procId + '}' + "`n")
  $p.Write($b, 0, $b.Length); $p.Dispose()
}
function StartAgent([bool]$settings) {
  $env:SHOWORK_OPEN_SETTINGS = $(if ($settings) { '1' } else { '' })
  $p = Start-Process $Agent -PassThru
  Start-Sleep 3
  return $p
}
function SettingsWindow($p) {
  $c = New-Object System.Windows.Automation.PropertyCondition($A::ProcessIdProperty, $p.Id)
  for ($i = 0; $i -lt 20; $i++) {
    foreach ($w in $A::RootElement.FindAll($TP::Children, $c)) { if ($w.Current.Name -like 'ShoWork42*') { return $w } }
    Start-Sleep -Milliseconds 250
  }
  throw 'settings window not found'
}

$env:SHOWORK_PIPE = 'sw42-w2-set-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$env:SHOWORK_HOME = $Work
$env:SHOWORK_STATUS_FILE = "$Work\status.json"
$env:SHOWORK_DEBUG = '1'
$before = [W2]::AllRects(@())

# a console with two AI stand-ins (the shell and a child sharing its console)
$con = Start-Process conhost.exe -ArgumentList "powershell.exe -NoExit -NoProfile -Command `"`$host.UI.RawUI.WindowTitle='SW42-W2-SET'; Start-Process -NoNewWindow powershell -ArgumentList '-NoProfile','-Command','Start-Sleep 900'`"" -PassThru
Start-Sleep 3
$sh = (Get-CimInstance Win32_Process -Filter "ParentProcessId=$($con.Id) AND Name='powershell.exe'").ProcessId
$kid = (Get-CimInstance Win32_Process -Filter "ParentProcessId=$sh AND Name='powershell.exe'").ProcessId
Check 'two processes share the test console' ($sh -and $kid) "shell=$sh child=$kid"

function Invoke($root, $name) {
  $e = Find $root $name; $p = $null
  if ($e.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$p)) { $p.Invoke() }
  else { [Click]::On([IntPtr]$e.Current.NativeWindowHandle) }      # custom control (a Pane to UIA): a click message to OUR window
  Start-Sleep -Milliseconds 400
}
function Shot($p, $file) {
  $h = [W2]::Of([uint32]$p.Id) | Where-Object { [W2]::Title($_) -like 'ShoWork42*' } | Select-Object -First 1
  if ($h) { [W2]::Shot($h, (Join-Path $Work $file)) }
}
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class Click {
  [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  public static void On(IntPtr hwnd) { SendMessage(hwnd, 0x201, (IntPtr)1, (IntPtr)0x00100010); SendMessage(hwnd, 0x202, IntPtr.Zero, (IntPtr)0x00100010); }
}
"@
$ag = $null
try {
  # 1. idle agent (no settings window): baseline cost
  $ag = StartAgent $false
  $ag.Refresh(); $c0 = $ag.TotalProcessorTime.TotalMilliseconds; Start-Sleep 10; $ag.Refresh()
  $idleCpu = 100 * ($ag.TotalProcessorTime.TotalMilliseconds - $c0) / 10000 / [Environment]::ProcessorCount
  $idleWs = $ag.WorkingSet64 / 1MB
  Check ('idle agent CPU {0:N2}% < 1%' -f $idleCpu) ($idleCpu -lt 1) ''
  Check ('idle agent working set {0:N1} MB < 60 MB' -f $idleWs) ($idleWs -lt 60) ('private {0:N1} MB' -f ($ag.PrivateMemorySize64 / 1MB))
  Stop-Process -Id $ag.Id; Start-Sleep 1

  # 2. agent + settings window
  $ag = StartAgent $true
  $win = SettingsWindow $ag
  $ag.Refresh(); $openWs = $ag.WorkingSet64 / 1MB
  Write-Host ('  info: working set with the settings window open {0:N1} MB' -f $openWs)
  Send 'working' $sh; Start-Sleep 2
  Check 'working lights purple' ((GlowState) -eq 'working') (GlowState)
  Send 'done' $kid; Start-Sleep 1
  Check 'working + done in one window shows done' ((GlowState) -eq 'done') (GlowState)

  Toggle $win '顯示已完成的光'; Start-Sleep 1
  Check 'done switched off: the window shows its next lit state (working)' ((GlowState) -eq 'working') (GlowState)
  Toggle $win '顯示工作中的光'; Start-Sleep 1
  Check 'working off too: nothing lit' ((GlowState) -eq 'none') (GlowState)
  Toggle $win '顯示工作中的光'; Toggle $win '顯示已完成的光'; Start-Sleep 1
  Check 'both back on: done again' ((GlowState) -eq 'done') (GlowState)

  # live restyle: select the 已完成 card, pick 流光繞行, move the sliders
  Invoke $win '已完成光芒預覽'
  Check 'invoking the 已完成 card selects it' ((Find $win '已完成　外觀') -ne $null) ''
  Pick $win '款式' '流光繞行'; Start-Sleep 1
  $log = Get-Content "$Work\agent.log" -Raw
  Check 'style change restyles the live glow' ($log -match 'style=Orbit parts=4') ''
  SetRange $win '亮度' 12; SetRange $win '寬度' 15; SetRange $win '速度' 20; Start-Sleep 1
  Shot $ag 'settings-glow.png'
  Page $win '一般'
  Toggle $win '視窗數量變動時自動排版'
  Start-Sleep 1
  Shot $ag 'settings-general.png'
  $s = Settings
  Check 'settings.json: done = orbit, brightness 1.2, width 1.5, speed 2.0' (($s.looks.done.style -eq 'orbit') -and ($s.looks.done.brightness -eq 1.2) -and ($s.looks.done.width -eq 1.5) -and ($s.looks.done.speed -eq 2)) ($s.looks.done | ConvertTo-Json -Compress)
  Check 'settings.json: working untouched' (($s.looks.working.style -eq 'breathe') -and ($s.looks.working.hex -eq '#9E66FF')) ($s.looks.working | ConvertTo-Json -Compress)
  Check 'settings.json: autoArrange on' ($s.general.autoArrange -eq $true) ($s.general | ConvertTo-Json -Compress)
  $runKey = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue).ShoWork42
  Check '開機時啟動 shows the registry state (not changed by the test)' ((ToggleState $win '開機時啟動') -eq $(if ($runKey) { 'On' } else { 'Off' })) ''

  $win.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close(); Start-Sleep 3
  $ag.Refresh(); $closedWs = $ag.WorkingSet64 / 1MB
  Write-Host ('  info: working set after closing it {0:N1} MB' -f $closedWs)
  Check 'settings window closed (disposed)' (@([W2]::Of([uint32]$ag.Id) | Where-Object { [W2]::Title($_) -like 'ShoWork42*' }).Count -eq 0) ''
  Check 'glow kept its new look after closing' ((GlowState) -eq 'done') (GlowState)
  Stop-Process -Id $ag.Id; Start-Sleep 1

  # 3. round trip: a new agent reads the same settings.json
  $ag = StartAgent $true
  $win = SettingsWindow $ag
  Check 'reload: 工作中 still 亮度 1.0' ((GetRange $win '亮度') -eq 10) (GetRange $win '亮度')
  Invoke $win '已完成光芒預覽'
  Check 'reload: 已完成 亮度 1.2 / 寬度 1.5 / 速度 2.0' (((GetRange $win '亮度') -eq 12) -and ((GetRange $win '寬度') -eq 15) -and ((GetRange $win '速度') -eq 20)) ''
  Page $win '一般'
  Check 'reload: autoArrange kept' ((ToggleState $win '視窗數量變動時自動排版') -eq 'On') ''
  $win.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close(); Start-Sleep 1
}
finally {
  if ($ag) { Stop-Process -Id $ag.Id -ErrorAction SilentlyContinue }
  Stop-Process -Id $kid -ErrorAction SilentlyContinue; Stop-Process -Id $sh -ErrorAction SilentlyContinue; Stop-Process -Id $con.Id -ErrorAction SilentlyContinue
}
Start-Sleep 1
$after = [W2]::AllRects(@())
$moved = $before | Where-Object { $after -notcontains $_ } | Where-Object { $hw = $_.Split(':')[0]; $after | Where-Object { $_.Split(':')[0] -eq $hw } }
Check 'other windows untouched' (@($moved).Count -eq 0) ("moved: " + ($moved -join ' '))
Write-Host "TOTAL pass=$pass fail=$fail"
