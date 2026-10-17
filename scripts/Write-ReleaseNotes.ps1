param([switch]$CheckOnly)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$match = [regex]::Match((Get-Content (Join-Path $projectRoot 'pubspec.yaml') -Raw), '(?m)^version:\s*((\d+\.\d+\.\d+)\+\d+)\s*$')
if (!$match.Success) { throw 'pubspec.yaml 需要版本号与构建号' }
$fullVersion = $match.Groups[1].Value
$version = $match.Groups[2].Value
foreach ($name in @('README.md', 'RELEASE_NOTES.md')) {
  $content = Get-Content (Join-Path $projectRoot $name) -Raw
  if (!$content.Contains("<!-- release-version: $fullVersion -->")) {
    throw "$name 未更新到 $fullVersion，请审阅完整内容并更新版本标记后再打包。"
  }
}
if ($CheckOnly) { return }
$dist = Join-Path $projectRoot 'dist'
New-Item -ItemType Directory -Path $dist -Force | Out-Null
$destination = Join-Path $dist "HowDoI-$version-release-notes.md"
Copy-Item -LiteralPath (Join-Path $projectRoot 'RELEASE_NOTES.md') -Destination $destination -Force
Write-Output "版本更新说明已生成：$destination"
