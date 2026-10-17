param([switch]$SkipBuild)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
Set-Location $projectRoot
& "$PSScriptRoot/Write-ReleaseNotes.ps1" -CheckOnly
$match = [regex]::Match((Get-Content pubspec.yaml -Raw), '(?m)^version:\s*((\d+\.\d+\.\d+)\+(\d+))')
if (!$match.Success) { throw 'pubspec.yaml 需要版本号与构建号' }
$fullVersion = $match.Groups[1].Value
$version = $match.Groups[2].Value
$numericVersion = "$version.$($match.Groups[3].Value)"
$compiler = Join-Path $projectRoot '.tools/nsis/makensis.exe'
if (!(Test-Path -LiteralPath $compiler)) { throw '请将 NSIS 3.11 解压到 .tools/nsis（需包含 makensis.exe 和 Include 等目录）。' }
if (!$SkipBuild) {
  & "$PSScriptRoot/Build-Windows.ps1"
  if ($LASTEXITCODE -ne 0) { throw 'Windows 构建失败' }
}
$releaseDir = Join-Path $projectRoot 'build/windows/x64/runner/Release'
$exe = Join-Path $releaseDir 'howdoi.exe'
if (!(Test-Path -LiteralPath $exe) -or (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion -ne $fullVersion) { throw 'Windows EXE 缺失或版本不符，请重新构建' }
New-Item -ItemType Directory -Path work/installer,dist -Force | Out-Null
$manifest = Join-Path $projectRoot 'work/installer/uninstall-files.nsh'
# Only remove packaged files and then empty directories; retain user-added files.
$lines = @(Get-ChildItem -LiteralPath $releaseDir -File -Recurse | ForEach-Object {
  $relative = $_.FullName.Substring($releaseDir.Length + 1).Replace('$','$$')
  'Delete "$INSTDIR\' + $relative + '"'
})
$lines += @(Get-ChildItem -LiteralPath $releaseDir -Directory -Recurse | Sort-Object { $_.FullName.Length } -Descending | ForEach-Object {
  $relative = $_.FullName.Substring($releaseDir.Length + 1).Replace('$','$$')
  'RMDir "$INSTDIR\' + $relative + '"'
})
$lines | Set-Content -LiteralPath $manifest -Encoding utf8
& $compiler /V3 /INPUTCHARSET UTF8 "/DPROJECT_ROOT=$projectRoot" "/DRELEASE_DIR=$releaseDir" "/DUNINSTALL_FILES=$manifest" "/DVERSION=$version" "/DFULL_VERSION=$fullVersion" "/DNUMERIC_VERSION=$numericVersion" "$PSScriptRoot/windows-installer.nsi"
if ($LASTEXITCODE -ne 0) { throw '安装包编译失败' }
$package = "dist/HowDoI-$version-windows-x64-setup.exe"
$hash = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash.ToLowerInvariant()
$checksumFile = 'dist/SHA256SUMS.txt'
$packageName = Split-Path $package -Leaf
$existing = if (Test-Path -LiteralPath $checksumFile) { @(Get-Content -LiteralPath $checksumFile | Where-Object { $_ -and !$_.EndsWith($packageName) }) } else { @() }
@($existing; "$hash  $packageName") | Set-Content -LiteralPath $checksumFile -Encoding ascii
Write-Output "Windows 安装包已生成：$package"
& "$PSScriptRoot/Write-ReleaseNotes.ps1"
