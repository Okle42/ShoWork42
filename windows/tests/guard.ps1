# 每個會開關終端機視窗的測試一開頭都 dot-source 這個檔。
# 使用者自己的 agent 若開著自動排版，測試視窗一出現或消失，它就會（照規則）重排使用者的終端機視窗。
# 那不是測試能控制的，所以直接拒絕執行，請使用者先關掉自動排版。
$realSettings = Join-Path $env:LOCALAPPDATA 'ShoWork42\settings.json'
$realAuto = $false
try { if (Test-Path $realSettings) { $realAuto = [bool]((Get-Content $realSettings -Raw -Encoding UTF8 | ConvertFrom-Json).general.autoArrange) } } catch { }
if ($realAuto) {
  Write-Host '拒絕執行：你自己的 ShoWork42 開著「自動排版」，測試開關視窗會讓它重排你的終端機視窗。請先在系統匣選單取消勾選「自動排版」。' -ForegroundColor Red
  [Environment]::Exit(2)          # exit inside a dot-sourced file would not stop the caller
}
