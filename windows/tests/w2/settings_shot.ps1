param([string]$Agent, [string]$Out, [string]$Data, [int]$Wait = 4, [switch]$Keep)
# Start a private agent (own pipe, own data folder) with the settings window open, capture only that window.
Add-Type -Path "$PSScriptRoot\Win.cs" -ReferencedAssemblies System.Drawing
[W2]::SetProcessDPIAware() | Out-Null
$env:SHOWORK_PIPE = "sw42-w2-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8)
$env:SHOWORK_HOME = $Data
$env:SHOWORK_STATUS_FILE = "$Data\status.json"
$env:SHOWORK_DEBUG = "1"
$env:SHOWORK_OPEN_SETTINGS = "1"
$p = Start-Process $Agent -PassThru
Start-Sleep $Wait
$wins = [W2]::Of([uint32]$p.Id)
foreach ($h in $wins) { "win $h '$([W2]::Title($h))'" }
$s = $wins | Where-Object { [W2]::Title($_) -like 'ShoWork42*' } | Select-Object -First 1
if ($s) { [W2]::Shot($s, $Out); "shot $Out" }
$p.Refresh(); "ws={0:N1}MB private={1:N1}MB" -f ($p.WorkingSet64 / 1MB), ($p.PrivateMemorySize64 / 1MB)
"pid=$($p.Id) settingsHwnd=$s"
if (-not $Keep) { Stop-Process -Id $p.Id; "stopped $($p.Id)" }
