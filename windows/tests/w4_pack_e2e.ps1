# ShoWork42 W4 驗收：dist\ShoWork42.exe 與 ShoWork42-small.exe 各跑一輪「安裝 → 發光 → 更新 → 解除安裝」。
# 全部在沙盒裡：SHOWORK_HOME（安裝目錄）、SHOWORK_REG_ROOT（開機啟動與「應用程式」清單的登錄機碼）、SHOWORK_PIPE、
# settings.json 用複本；不碰使用者真的 agent、設定與登錄檔。只動本腳本自己開的主控台視窗；其他視窗前後比對。
# 用法：powershell -ExecutionPolicy Bypass -File w4_pack_e2e.ps1   （先跑 windows\pack.ps1）
param([string]$Out = (Join-Path $PSScriptRoot 'w4_result.txt'))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'guard.ps1')
$dist = Join-Path $PSScriptRoot '..\dist'
$probe = Join-Path $PSScriptRoot 'Sw42Probe\bin\Release\net8.0-windows\Sw42Probe.exe'
$results = New-Object System.Collections.Generic.List[string]
$pass = 0; $fail = 0
function Check($name, $ok, $detail = '') {
  if ($ok) { $script:pass++; Write-Host "  PASS $name  $detail" -ForegroundColor Green } else { $script:fail++; Write-Host "  FAIL $name  $detail" -ForegroundColor Red }
  $results.Add(('{0} {1}  {2}' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail))
}
function Windows { $m = @{}; foreach ($l in (& $probe windows)) { $f = $l -split "`t"; $m[$f[0]] = "$($f[1])/$($f[2])" }; $m }
function Run($exe, $argline) {
  # raw command line; WinExe, so wait for the process itself
  $psi = New-Object Diagnostics.ProcessStartInfo $exe, $argline; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $p = [Diagnostics.Process]::Start($psi); if (-not $p.WaitForExit(60000)) { $p.Kill(); return -1 }; $p.ExitCode
}
function WaitUntil([scriptblock]$c, [int]$ms) { $u = (Get-Date).AddMilliseconds($ms); while ((Get-Date) -lt $u) { if (& $c) { return $true }; Start-Sleep -Milliseconds 100 }; $false }
Add-Type -Name U -Namespace W4 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
'@

$before = Windows
$regRoot = 'Software\ShoWork42-e2e\CurrentVersion'
$realRun = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue).ShoWork42
$realUninstall = Test-Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ShoWork42'
$realSettingsHash = (Get-FileHash (Join-Path $env:USERPROFILE '.claude\settings.json')).Hash

# a test console the installed agent can light up
$con = Start-Process conhost.exe -ArgumentList "powershell.exe -NoExit -NoProfile -Command `"`$host.UI.RawUI.WindowTitle='SW42-W4'`"" -PassThru
Start-Sleep 2
$shell = (Get-CimInstance Win32_Process -Filter "ParentProcessId=$($con.Id) AND Name='powershell.exe'").ProcessId

foreach ($name in 'ShoWork42-small.exe', 'ShoWork42.exe') {
  Write-Host "--- $name ---" -ForegroundColor Cyan
  # LOCALAPPDATA, not TEMP: TEMP is often an 8.3 short path that Remove-Item can't resolve once the folder is gone
  $work = Join-Path $env:LOCALAPPDATA ('Temp\sw42-w4-' + [IO.Path]::GetFileNameWithoutExtension($name))
  if (Test-Path $work) { Remove-Item -Recurse -Force $work }
  New-Item -ItemType Directory -Force "$work\download", "$work\home", "$work\claude" | Out-Null
  $exe = Join-Path "$work\download" $name
  Copy-Item (Join-Path $dist $name) $exe
  $settings = "$work\claude\settings.json"
  # not a copy of the real file (it already has the real ShoWork hooks): another tool's hook, CRLF, no final newline
  [IO.File]::WriteAllText($settings, "{`r`n  `"theme`": `"dark`",`r`n  `"hooks`": {`r`n    `"Stop`": [ { `"hooks`": [ { `"type`": `"command`", `"command`": `"echo other-tool`" } ] } ]`r`n  }`r`n}")
  $original = [IO.File]::ReadAllBytes($settings)
  $env:SHOWORK_HOME = "$work\home"; $env:SHOWORK_REG_ROOT = $regRoot; $env:SHOWORK_PIPE = "sw42-w4-$PID"
  $env:SHOWORK_STATUS_FILE = "$work\status.json"; $env:SHOWORK_DEBUG = '1'
  $bin = "$work\home\bin"
  $reg = "HKCU:\$regRoot"

  # double-click (no arguments): only asks, installs nothing
  $p = Start-Process $exe -PassThru
  $asked = WaitUntil { @(& $probe windows | Where-Object { ($_ -split "`t")[3] -eq "$($p.Id)" }).Count -gt 0 } 20000
  $dlg = @(& $probe windows | Where-Object { ($_ -split "`t")[3] -eq "$($p.Id)" })
  Check "$name 雙擊：先跳出詢問視窗" $asked (($dlg | ForEach-Object { ($_ -split "`t")[5] }) -join ' | ')
  foreach ($l in $dlg) { [W4.U]::PostMessage([IntPtr][long](($l -split "`t")[0]), 0x10, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null }
  $closed = $p.WaitForExit(10000)
  Check "$name 雙擊後取消：什麼都沒裝" ($closed -and -not (Test-Path $bin) -and -not (Test-Path "$reg\Uninstall\ShoWork42"))

  # install (what the 安裝 button does)
  $code = Run $exe "--install --quiet --settings `"$settings`""
  Check "$name --install 結束碼 0" ($code -eq 0) "exit=$code"
  $files = @(Get-ChildItem $bin -ErrorAction SilentlyContinue | ForEach-Object Name | Sort-Object)
  Check "$name 安裝目錄只有兩個檔" (($files -join ',') -eq 'showork.exe,ShoWorkAgent.exe') ($files -join ',')
  Check "$name ShoWorkAgent.exe 就是下載的那個 exe" ((Get-FileHash "$bin\ShoWorkAgent.exe").Hash -eq (Get-FileHash $exe).Hash)
  $cliSize = (Get-Item "$bin\showork.exe").Length / 1MB
  Check ("$name showork.exe 是原生版（{0:N1} MB，不需要 dll）" -f $cliSize) ($cliSize -gt 0.8 -and $cliSize -lt 5)
  $cons = & "$bin\showork.exe" console $shell
  Check "$name showork.exe console 能用" (($cons -split "`t")[1] -ne '0') "$cons"
  $s = Get-Content $settings -Raw | ConvertFrom-Json
  $cmds = @($s.hooks.PSObject.Properties | ForEach-Object { $_.Value } | ForEach-Object { $_.hooks } | ForEach-Object { $_.command })
  $want = '"' + ($bin -replace '\\', '/') + '/showork.exe"'
  Check "$name hooks 8 個都指向安裝目錄的 showork.exe，別的工具的 hook 還在" ((@($cmds | Where-Object { $_.StartsWith($want) }).Count -eq 8) -and ($cmds -contains 'echo other-tool')) "$($cmds.Count) 個"
  Check "$name 開機啟動（測試機碼）" ((Get-ItemProperty "$reg\Run").ShoWork42 -eq "`"$bin\ShoWorkAgent.exe`"")
  $u = Get-ItemProperty "$reg\Uninstall\ShoWork42" -ErrorAction SilentlyContinue
  Check "$name 列在「應用程式」：名稱、版本、解除安裝指令" ($u -and $u.DisplayName -eq 'ShoWork42' -and $u.DisplayVersion -eq '0.4.0' -and $u.UninstallString -eq "`"$bin\ShoWorkAgent.exe`" --uninstall") "$($u.DisplayVersion) $($u.UninstallString)"
  $agentUp = WaitUntil { Test-Path $env:SHOWORK_STATUS_FILE } 15000
  $agent = Get-Process ShoWorkAgent -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq "$bin\ShoWorkAgent.exe" }
  Check "$name 裝好的 agent 在跑" ($agentUp -and $agent) "$($agent.Id)"

  # the hook exactly as settings.json has it, run through Git Bash like Claude Code does (+ --pid: our test console)
  $bash = $env:CLAUDE_CODE_GIT_BASH_PATH; if (-not $bash) { $bash = 'C:\Program Files\Git\bin\bash.exe' }
  $hook = ($cmds | Where-Object { $_ -like '*emit done*' } | Select-Object -First 1) + " --pid $shell"
  $code = Run $bash ('-c "' + $hook.Replace('"', '\"') + '"')
  $lit = WaitUntil { $st = Get-Content $env:SHOWORK_STATUS_FILE -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json; $st -and @($st.glows | Where-Object { $_.state -eq 'done' }).Count -eq 1 } 10000
  Check "$name 經 Git Bash 執行 hook → 測試視窗發綠光" ($code -eq 0 -and $lit) "exit=$code"
  Start-Sleep 5
  $agent.Refresh()
  Check ("$name 裝好的 agent 記憶體 {0:N1} MB < 60 MB" -f ($agent.WorkingSet64 / 1MB)) ($agent.WorkingSet64 / 1MB -lt 60) ('private {0:N1} MB' -f ($agent.PrivateMemorySize64 / 1MB))

  # install again = update: same result, hooks not duplicated
  $code = Run $exe "--install --quiet --settings `"$settings`""
  $s2 = Get-Content $settings -Raw | ConvertFrom-Json
  $n2 = @($s2.hooks.PSObject.Properties | ForEach-Object { $_.Value } | ForEach-Object { $_.hooks }).Count
  Check "$name 再裝一次（更新）：hooks 不重複" ($code -eq 0 -and $n2 -eq 9) "hooks=$n2（8 個 ShoWork＋1 個別的工具）"
  Check "$name 更新後 agent 重新啟動" (WaitUntil { @(Get-Process ShoWorkAgent -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq "$bin\ShoWorkAgent.exe" }).Count -eq 1 } 10000)

  # uninstall the way Settings → Apps does it: the installed exe, which deletes its own folder after exiting
  $code = Run "$bin\ShoWorkAgent.exe" "--uninstall --quiet --settings `"$settings`""
  Check "$name --uninstall 結束碼 0" ($code -eq 0) "exit=$code"
  Check "$name 解除安裝：安裝目錄刪掉" (WaitUntil { -not (Test-Path $bin) } 20000)
  Check "$name 解除安裝：settings.json 逐位元組回到原本" ([Convert]::ToBase64String([IO.File]::ReadAllBytes($settings)) -eq [Convert]::ToBase64String($original))
  Check "$name 解除安裝：開機啟動與「應用程式」項目都拿掉" (-not (Get-ItemProperty "$reg\Run" -ErrorAction SilentlyContinue).ShoWork42 -and -not (Test-Path "$reg\Uninstall\ShoWork42"))
  Check "$name 解除安裝：agent 停了" (-not (Get-Process ShoWorkAgent -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$work*" }))
  foreach ($v in 'SHOWORK_HOME', 'SHOWORK_REG_ROOT', 'SHOWORK_PIPE', 'SHOWORK_STATUS_FILE', 'SHOWORK_DEBUG') { Remove-Item "Env:$v" }
}

Stop-Process -Id $shell -ErrorAction SilentlyContinue; Stop-Process -Id $con.Id -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force 'HKCU:\Software\ShoWork42-e2e' -ErrorAction SilentlyContinue
Check '使用者真的開機啟動、「應用程式」項目、settings.json 都沒被動到' (((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue).ShoWork42 -eq $realRun) -and ((Test-Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ShoWork42') -eq $realUninstall) -and ((Get-FileHash (Join-Path $env:USERPROFILE '.claude\settings.json')).Hash -eq $realSettingsHash))
$after = Windows
$moved = foreach ($k in $before.Keys) { if ($after.ContainsKey($k) -and $after[$k] -ne $before[$k]) { "$k $($before[$k]) → $($after[$k])" } }
Check ('其他視窗位置／大小不變（{0} 個）' -f $before.Count) (@($moved).Count -eq 0) ($moved -join '; ')
$results.Add("TOTAL pass=$pass fail=$fail")
$results | Out-File $Out -Encoding utf8
Write-Host "結果：$pass 通過、$fail 失敗" -ForegroundColor Cyan
