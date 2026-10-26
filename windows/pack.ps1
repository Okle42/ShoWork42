# W4：打包成單一 exe，放在 windows\dist\
#   ShoWork42.exe        內含 .NET runtime（約 155 MB），下載就能用
#   ShoWork42-small.exe  約 1.5 MB，需要先裝 .NET 8 Desktop Runtime（沒裝時 Windows 會跳出官方下載連結）
# 兩個都內含原生版 showork.exe（hook 用），雙擊後會先問要不要安裝。
# 需要：.NET 8 SDK、Visual Studio Build Tools（C++，NativeAOT 用）。
# 用法：powershell -ExecutionPolicy Bypass -File pack.ps1 [-Version 0.4.0]
param([string]$Version = '')
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$work = Join-Path $root 'ShoWork.Win\obj\pack'
$dist = Join-Path $root 'dist'
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work, $dist | Out-Null
# the AOT linker finds MSVC through vswhere.exe, which is not on PATH until the next sign-in after installing Build Tools
$env:PATH = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer;$env:PATH"
$ver = @(); if ($Version) { $ver = @("-p:Version=$Version") }

function Run-Dotnet([string[]]$a) {
  & dotnet.exe @a -nologo -v q
  if ($LASTEXITCODE -ne 0) { throw "dotnet $($a -join ' ') failed ($LASTEXITCODE)" }
}

Write-Host '1/3 showork.exe（NativeAOT）' -ForegroundColor Cyan
Run-Dotnet @('publish', "$root\showork\showork.csproj", '-c', 'Release', '-r', 'win-x64', '-o', "$work\cli")
$cli = Join-Path $work 'cli\showork.exe'

$variants = @(
  @{ name = 'ShoWork42.exe'; selfContained = 'true' },
  @{ name = 'ShoWork42-small.exe'; selfContained = 'false' }
)
$i = 1
foreach ($v in $variants) {
  $i++
  Write-Host "$i/3 $($v.name)" -ForegroundColor Cyan
  $out = Join-Path $work $v.name
  Run-Dotnet (@('publish', "$root\ShoWork.Win\ShoWork.Win.csproj", '-c', 'Release', '-r', 'win-x64', '--self-contained', $v.selfContained,
            '-p:PublishSingleFile=true', '-p:IncludeNativeLibrariesForSelfExtract=true', '-p:DebugType=none',
            "-p:PackShowork=$cli", '-o', $out) + $ver)
  $exe = @(Get-ChildItem $out -Filter *.exe)
  if ($exe.Count -ne 1) { throw "expected exactly one exe in $out, got: $($exe.Name -join ', ')" }
  Copy-Item $exe[0].FullName (Join-Path $dist $v.name) -Force
}
# the next normal build must not reuse the packed (resource-embedding) compile
Remove-Item -Recurse -Force (Join-Path $root 'ShoWork.Win\obj\Release') -ErrorAction SilentlyContinue

$sums = foreach ($v in $variants) {
  $f = Get-Item (Join-Path $dist $v.name)
  $h = (Get-FileHash $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
  Write-Host ('  {0,-22} {1,7:N1} MB  {2}  版本 {3}' -f $f.Name, ($f.Length / 1MB), $h, $f.VersionInfo.ProductVersion.Split('+')[0])
  "$h  $($f.Name)"
}
$sums | Out-File (Join-Path $dist 'SHA256SUMS.txt') -Encoding ascii
Write-Host "完成：$dist" -ForegroundColor Green
