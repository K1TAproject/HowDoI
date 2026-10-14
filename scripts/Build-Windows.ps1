$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
Set-Location $projectRoot
$version = ([regex]::Match((Get-Content pubspec.yaml -Raw), '(?m)^version:\s*(\d+\.\d+\.\d+)')).Groups[1].Value
if (!$version) { throw 'pubspec.yaml 缺少版本号' }
& "$PSScriptRoot/Flutter.ps1" build windows --release
if ($LASTEXITCODE -ne 0) { throw 'Windows 构建失败' }
New-Item -ItemType Directory -Path dist -Force | Out-Null
$releaseDir = Join-Path $projectRoot 'build/windows/x64/runner/Release'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
if (Test-Path -LiteralPath $vswhere) {
  $vs = & $vswhere -latest -products '*' -property installationPath
  if ($vs) {
    $crt = Get-ChildItem -LiteralPath (Join-Path $vs 'VC/Redist/MSVC') -Directory |
      Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName 'x64/Microsoft.VC143.CRT' } |
      Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($crt) { Get-ChildItem -LiteralPath $crt -Filter '*.dll' | Copy-Item -Destination $releaseDir -Force }
  }
}
$package = "dist/HowDoI-$version-windows-x64.zip"
Compress-Archive -Path "$releaseDir/*" -DestinationPath $package -Force
$hash = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $(Split-Path $package -Leaf)" | Set-Content -LiteralPath dist/SHA256SUMS.txt -Encoding ascii
Write-Output "Windows 便携包已生成：$package"
