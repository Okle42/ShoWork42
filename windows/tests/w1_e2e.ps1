# ShoWork42 Windows W1 驗收：真實 Claude Code 在 conhost 與 Windows Terminal 各跑一個
#
# 前提：已執行 ShoWorkAgent.exe --install（hooks 在 settings.json、binaries 在 %LOCALAPPDATA%\ShoWork42\bin），
#       windows\tests\Sw42Probe 已 build（Release）。
# 用法：powershell -ExecutionPolicy Bypass -File w1_e2e.ps1 [-Out w1_result.txt] [-Model haiku]
#
# 規矩：只操作本腳本自己開的視窗（hwnd 白名單）；前後比對其他所有視窗的位置與大小。
# 會用掉少量 Claude 用量（Haiku，約 10 個很短的提示）。
param([string]$Out = (Join-Path $PSScriptRoot 'w1_result.txt'), [string]$Model = 'haiku')
$ErrorActionPreference = 'Stop'
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class W {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint c);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, UIntPtr e);
}
'@
$bin = Join-Path $env:LOCALAPPDATA 'ShoWork42\bin'
$agentExe = Join-Path $bin 'ShoWorkAgent.exe'
$showork = Join-Path $bin 'showork.exe'
$probe = Join-Path $PSScriptRoot 'Sw42Probe\bin\Release\net8.0-windows\Sw42Probe.exe'
foreach ($f in $agentExe, $showork, $probe) { if (-not (Test-Path $f)) { throw "missing $f" } }
$work = Join-Path $env:TEMP ('sw42-e2e-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force "$work\home", "$work\conhost", "$work\wt" | Out-Null
$fso = New-Object -ComObject Scripting.FileSystemObject
$results = New-Object System.Collections.Generic.List[string]
$pass = 0; $fail = 0
function Check($name, $ok, $detail = '') {
  if ($ok) { $script:pass++; Write-Host "  PASS $name  $detail" -ForegroundColor Green } else { $script:fail++; Write-Host "  FAIL $name  $detail" -ForegroundColor Red }
  $results.Add(('{0} {1}  {2}' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail))
}
function Metric($name, $value) { Write-Host "  METRIC $name = $value" -ForegroundColor Cyan; $results.Add("METRIC $name = $value") }
function Probe { & $probe @args }
function Run($exe, $arguments) {
  # raw command line (PowerShell 5.1 mangles embedded quotes when calling native programs)
  $psi = New-Object Diagnostics.ProcessStartInfo $exe, $arguments
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $sw = [Diagnostics.Stopwatch]::StartNew(); $p = [Diagnostics.Process]::Start($psi); $p.WaitForExit(); $sw.Stop()
  return @{ ms = $sw.Elapsed.TotalMilliseconds; code = $p.ExitCode }
}
function Windows {
  $m = @{}
  foreach ($l in (Probe windows)) { $f = $l -split "`t"; $m[$f[0]] = @{ rect = $f[1]; iconic = $f[2]; pid = $f[3]; cls = $f[4]; title = $f[5] } }
  return $m
}

Write-Host '=== ShoWork42 W1 驗收 ===' -ForegroundColor Cyan
Write-Host '會開一個 conhost 視窗和一個 Windows Terminal 視窗各跑一個 Claude（Haiku），約 3–4 分鐘。你的其他視窗不會被動到。'

# ---- 0. 其他視窗的位置（agent 停掉之後拍，光暈不算）
Get-Process ShoWorkAgent -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 800
$keepFront = [W]::GetForegroundWindow()
$before = Windows

# ---- 驗收 2：agent 沒在跑時 emit，20 次都 exit 0 且 < 200 ms
$direct = 1..20 | ForEach-Object { Run $showork 'emit working --agent claude' }
$maxDirect = ($direct | ForEach-Object { $_.ms } | Measure-Object -Maximum).Maximum
Check 'emit（agent 沒跑）20 次都 exit 0' (@($direct | Where-Object { $_.code -ne 0 }).Count -eq 0)
Check ('emit（agent 沒跑）最大 {0:N0} ms < 200 ms' -f $maxDirect) ($maxDirect -lt 200) ('全部：' + (($direct | ForEach-Object { [int]$_.ms }) -join ' '))
$bash = $env:CLAUDE_CODE_GIT_BASH_PATH; if (-not $bash) { $bash = 'C:\Program Files\Git\bin\bash.exe' }
$viaBash = 1..10 | ForEach-Object { Run $bash ('-c "\"' + $showork.Replace('\', '/') + '\" emit working --agent claude"') }
Metric 'hook 實際路徑（Git Bash + showork.exe）最大 ms' ('{0:N0}（全部 {1}；exit {2}）' -f ($viaBash | ForEach-Object { $_.ms } | Measure-Object -Maximum).Maximum, (($viaBash | ForEach-Object { [int]$_.ms }) -join ' '), (($viaBash | ForEach-Object { $_.code } | Sort-Object -Unique) -join ','))

# ---- agent（同一個 binary，加上狀態檔與記錄檔）
$env:SHOWORK_HOME = "$work\home"; $env:SHOWORK_DEBUG = '1'; $env:SHOWORK_STATUS_FILE = "$work\home\status.json"
$agent = Start-Process $agentExe -PassThru
Remove-Item Env:SHOWORK_HOME, Env:SHOWORK_DEBUG, Env:SHOWORK_STATUS_FILE
$log = "$work\home\agent.log"
function Status {
  for ($i = 0; $i -lt 20; $i++) { try { return Get-Content "$work\home\status.json" -Raw -ErrorAction Stop | ConvertFrom-Json } catch { Start-Sleep -Milliseconds 50 } }
}
function TabOf($claudePid) { (Status).tabs | Where-Object { $_.pid -eq $claudePid } }
function GlowOn($hwnd) { (Status).glows | Where-Object { $_.target -eq [long]$hwnd } }
function WaitUntil([scriptblock]$cond, [int]$ms) {
  $until = (Get-Date).AddMilliseconds($ms)
  while ((Get-Date) -lt $until) { if (& $cond) { return $true }; Start-Sleep -Milliseconds 100 }
  return $false
}
function Events($claudePid) {
  if (-not (Test-Path $log)) { return @() }
  Get-Content $log | ForEach-Object {
    if ($_ -match "^\[(\d\d:\d\d:\d\d\.\d{3})\] EVT claude pid=$claudePid (\w+)(?: hook@(\d\d:\d\d:\d\d\.\d{3}))?") {
      [pscustomobject]@{ at = [TimeSpan]::Parse($Matches[1]); ev = $Matches[2]; hook = $(if ($Matches[3]) { [TimeSpan]::Parse($Matches[3]) } else { $null }) }
    }
  }
}
if (-not (WaitUntil { Test-Path "$work\home\status.json" } 10000)) { throw 'agent did not start' }

# ---- 開兩個 Claude（不讓它們繼承本機 Claude 工作階段的環境變數）
Get-ChildItem Env: | Where-Object { ($_.Name -like 'CLAUDE*' -and $_.Name -ne 'CLAUDE_CODE_GIT_BASH_PATH') -or $_.Name -like 'SHOWORK*' } | ForEach-Object { Remove-Item "Env:$($_.Name)" }
$t0 = Get-Date
$con = Start-Process conhost.exe -ArgumentList "cmd /c claude --model $Model" -WorkingDirectory "$work\conhost" -PassThru
$wtDir = $fso.GetFolder("$work\wt").ShortPath
Start-Process wt.exe -ArgumentList "-w sw42e2e nt -d $wtDir cmd /c claude --model $Model"
function ClaudeUnder([scriptblock]$parentOk) {
  foreach ($c in Get-CimInstance Win32_Process -Filter "Name='claude.exe'") {
    if ($c.CreationDate -lt $t0) { continue }
    $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($c.ParentProcessId)"
    if ($parent -and (& $parentOk $parent)) { return [int]$c.ProcessId }
  }
}
$PidA = $null; $PidB = $null
WaitUntil { $script:PidA = ClaudeUnder { param($p) $p.ParentProcessId -eq $con.Id }
            $script:PidB = ClaudeUnder { param($p) $p.ParentProcessId -ne $con.Id -and $p.CommandLine -like "*claude --model $Model*" }
            $script:PidA -and $script:PidB } 30000 | Out-Null
Check 'conhost 裡的 Claude 啟動' ([bool]$PidA) "pid=$PidA"
Check 'WT 裡的 Claude 啟動' ([bool]$PidB) "pid=$PidB"
if (-not ($PidA -and $PidB)) { throw 'Claude did not start' }

# 各自的視窗（白名單）：conhost = 主控台視窗；WT = 假視窗的 owner，而且必須是這次新開的視窗
function ConsoleOf($p) { $l = & $showork console $p; [IntPtr][long](($l -split "`t")[1]) }
$winA = ConsoleOf $PidA
$winB = [W]::GetWindow((ConsoleOf $PidB), 4)
Check 'conhost 視窗找得到' ($winA -ne [IntPtr]::Zero) "hwnd=$winA"
Check 'WT 測試視窗是新開的（不是既有視窗）' ($winB -ne [IntPtr]::Zero -and -not $before.ContainsKey([string]$winB)) "hwnd=$winB"
if ($winA -eq [IntPtr]::Zero -or $winB -eq [IntPtr]::Zero -or $before.ContainsKey([string]$winB)) { throw 'test windows not found' }
$whitelist = @([long]$winA, [long]$winB)
function Front($h) {
  if ($whitelist -notcontains [long]$h) { throw "refusing to touch non-test window $h" }
  Probe front $h | Out-Null
}
function ClearByKey($h) { Front $h; Probe shift }

# 信任資料夾對話框 → 輸入框
foreach ($p in $PidA, $PidB) {
  $r = Probe wait $p 'trust this folder|for shortcuts' 60000
  if ((Probe screen $p) -match 'trust this folder') { Probe key $p down; Start-Sleep -Milliseconds 300; Probe key $p enter }
  Probe wait $p 'for shortcuts' 60000 | Out-Null
}
function Say($p, $text) { Probe type $p $text; Start-Sleep -Milliseconds 300; Probe key $p enter }
$expected = @{ $PidA = [long]$winA; $PidB = [long]$winB }

# ---- 驗收 4：兩個 Claude 同時跑，光暈不串錯視窗
Say $PidA 'Count from 1 to 3, one number per line, nothing else.'
Say $PidB 'Count from 1 to 3, one number per line, nothing else.'
$both = WaitUntil { $a = TabOf $PidA; $b = TabOf $PidB; $a -and $b -and $a.state -eq 'done' -and $b.state -eq 'done' } 90000
$a = TabOf $PidA; $b = TabOf $PidB
Check '兩個同時：都變綠' $both "conhost=$($a.state) wt=$($b.state)"
Check '兩個同時：conhost 的 Claude 對到 conhost 視窗' ($a.window -eq $expected[$PidA]) "window=$($a.window)"
Check '兩個同時：WT 的 Claude 對到 WT 測試視窗' ($b.window -eq $expected[$PidB]) "window=$($b.window)"
Check '兩個同時：兩個視窗各有自己的綠光暈' ((GlowOn $winA).state -eq 'done' -and (GlowOn $winB).state -eq 'done')
ClearByKey $winA
$ok = WaitUntil { -not (TabOf $PidA) } 3000
Check '在 conhost 按鍵：只清 conhost 的綠' ($ok -and -not (GlowOn $winA) -and (GlowOn $winB).state -eq 'done')
ClearByKey $winB
Check '在 WT 按鍵：清 WT 的綠' (WaitUntil { -not (TabOf $PidB) -and -not (GlowOn $winB) } 3000)

# ---- 驗收 1：每種終端機各跑一輪
foreach ($case in @(@{ name = 'conhost'; pid = $PidA; win = $winA }, @{ name = 'WT'; pid = $PidB; win = $winB })) {
  $p = $case.pid; $w = $case.win; $n = $case.name
  Write-Host "--- $n ---" -ForegroundColor Cyan

  # 送出提示 → 紫 → 完成 → 綠 → 按鍵清除
  Say $p 'Reply with only the word pong.'
  $sawWorking = WaitUntil { $t = TabOf $p; $t -and $t.state -eq 'working' -and (GlowOn $w).state -eq 'working' } 15000
  Check "$n 送出提示 → 紫" $sawWorking
  Check "$n 完成 → 綠" ((WaitUntil { $t = TabOf $p; $t -and $t.state -eq 'done' } 60000) -and (GlowOn $w).state -eq 'done')
  Start-Sleep 2
  Check "$n 綠在沒按鍵時維持" ((TabOf $p).state -eq 'done')
  ClearByKey $w
  Check "$n 在該視窗按鍵後清除" (WaitUntil { -not (TabOf $p) -and -not (GlowOn $w) } 3000)

  # 權限提示 → 紅（量延遲）→ 允許 → 綠
  $dir = "sw42dir$(Get-Random)"
  Say $p "Use the Bash tool to run exactly this command: mkdir $dir"
  $tDialog = Probe wait $p 'Do you want to proceed' 60000
  $redOk = WaitUntil { $t = TabOf $p; $t -and $t.state -eq 'input' } 10000
  Check "$n 權限提示 → 紅" ($redOk -and (GlowOn $w).state -eq 'input') "對話框出現 $tDialog"
  Start-Sleep 8                                                      # 等晚到的 Notification，量它的延遲
  if ($tDialog -match '^\d\d:') {
    $td = [TimeSpan]::Parse($tDialog)
    $ins = @(Events $p | Where-Object { $_.ev -eq 'input' -and $_.at -gt $td.Add([TimeSpan]::FromSeconds(-2)) })
    if ($ins.Count -ge 1) { Metric "$n 權限提示：對話框出現 → 紅（PermissionRequest）秒" ('{0:N2}' -f ($ins[0].at - $td).TotalSeconds) }
    if ($ins.Count -ge 2) { Metric "$n 權限提示：對話框出現 → Notification(permission_prompt) hook 觸發 秒" ('{0:N2}' -f ($ins[-1].hook - $td).TotalSeconds) }
  }
  Probe key $p enter                                                 # 1. Yes
  Check "$n 允許後 → 綠" (WaitUntil { $t = TabOf $p; $t -and $t.state -eq 'done' } 60000)
  ClearByKey $w
  WaitUntil { -not (TabOf $p) } 3000 | Out-Null

  # AskUserQuestion → 紅（量延遲）→ 回答 → 綠
  Say $p 'Use the AskUserQuestion tool to ask me one question: tea or coffee? Then reply with my choice in one word.'
  $tDialog = Probe wait $p 'Enter to select' 60000
  $redOk = WaitUntil { $t = TabOf $p; $t -and $t.state -eq 'input' } 10000
  Check "$n AskUserQuestion → 紅" ($redOk -and (GlowOn $w).state -eq 'input') "對話框出現 $tDialog"
  Start-Sleep 8
  $afterQ = Events $p
  if ($tDialog -match '^\d\d:') {
    $td = [TimeSpan]::Parse($tDialog)
    $ins = @($afterQ | Where-Object { $_.ev -eq 'input' -and $_.at -gt $td.Add([TimeSpan]::FromSeconds(-2)) })
    if ($ins.Count -ge 1) { Metric "$n AskUserQuestion：對話框出現 → 紅 秒（負數 = 比對話框先到）" ('{0:N2}' -f ($ins[0].at - $td).TotalSeconds) }
    if ($ins.Count -ge 2) { Metric "$n AskUserQuestion：對話框出現 → Notification(elicitation) hook 觸發 秒" ('{0:N2}' -f ($ins[-1].hook - $td).TotalSeconds) }
    $purple = @($afterQ | Where-Object { $_.ev -eq 'working' -and $_.at -gt $td })
    Check "$n 等回答期間沒有紫蓋掉紅" ($purple.Count -eq 0 -and (TabOf $p).state -eq 'input')
  }
  Probe key $p enter                                                 # 1. Tea
  Check "$n 回答後 → 綠" (WaitUntil { $t = TabOf $p; $t -and $t.state -eq 'done' } 60000)

  # /exit → 光暈消失
  Probe type $p '/exit'; Start-Sleep -Milliseconds 800; Probe key $p enter
  Check "$n /exit → 光暈消失" (WaitUntil { -not (TabOf $p) -and -not (GlowOn $w) } 15000)
  Check "$n /exit → Claude 結束" (WaitUntil { -not (Get-Process -Id $p -ErrorAction SilentlyContinue) } 15000)
}
$dropped = @(Get-Content $log | Where-Object { $_ -match 'dropped: older' }).Count
Metric 'async 亂序被丟掉的舊事件數' $dropped

# ---- 驗收 5：閒置時 CPU／記憶體（30 秒）
Start-Sleep 3
$pr = Get-Process -Id $agent.Id
$c0 = $pr.TotalProcessorTime.TotalSeconds; $s0 = Get-Date
Start-Sleep 30
$pr.Refresh()
$cpu = 100 * ($pr.TotalProcessorTime.TotalSeconds - $c0) / ((Get-Date) - $s0).TotalSeconds / [Environment]::ProcessorCount
$glowsNow = @((Status).glows).Count
Check ('閒置 CPU {0:N2}% < 1%（期間光暈數 {1}）' -f $cpu, $glowsNow) ($cpu -lt 1)
Check ('記憶體 {0:N1} MB < 60 MB（working set）' -f ($pr.WorkingSet64 / 1MB)) ($pr.WorkingSet64 / 1MB -lt 60) ('private {0:N1} MB' -f ($pr.PrivateMemorySize64 / 1MB))

# ---- 驗收 7：其他視窗位置、大小完全不變
$after = Windows
$moved = foreach ($k in $before.Keys) {
  if ($after.ContainsKey($k) -and ($after[$k].rect -ne $before[$k].rect -or $after[$k].iconic -ne $before[$k].iconic)) {
    "$k [$($before[$k].cls)] $($before[$k].rect)/$($before[$k].iconic) → $($after[$k].rect)/$($after[$k].iconic)"
  }
}
Check ("其他視窗位置／大小不變（比對 {0} 個）" -f $before.Count) (@($moved).Count -eq 0) ($moved -join '; ')

# ---- 收尾：換回平常的 agent、焦點還給原本的視窗
Stop-Process -Id $agent.Id -ErrorAction SilentlyContinue
Start-Process $agentExe -WorkingDirectory $bin
[W]::keybd_event(0x10, 0, 0, [UIntPtr]::Zero); [W]::keybd_event(0x10, 0, 2, [UIntPtr]::Zero); [W]::SetForegroundWindow($keepFront) | Out-Null
Copy-Item $log (Join-Path (Split-Path $Out) 'w1_agent.log') -ErrorAction SilentlyContinue
$results.Add("TOTAL pass=$pass fail=$fail")
$results | Out-File $Out -Encoding utf8
Write-Host "結果：$pass 通過、$fail 失敗（$Out）" -ForegroundColor Cyan
