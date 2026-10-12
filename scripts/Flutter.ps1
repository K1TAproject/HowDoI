param([Parameter(ValueFromRemainingArguments=$true)][string[]]$FlutterArgs)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
Set-Location $projectRoot
$env:PUB_CACHE = Join-Path $projectRoot '.tools/pub-cache'
$env:ANDROID_HOME = Join-Path $projectRoot '.tools/android-sdk'
$env:GRADLE_USER_HOME = Join-Path $projectRoot '.tools/gradle'
$localJava = Join-Path $projectRoot '.local/java-home.txt'
if (Test-Path -LiteralPath $localJava) { $env:JAVA_HOME = (Get-Content -LiteralPath $localJava -Raw).Trim() }
$flutter = Join-Path $projectRoot '.tools/flutter/bin/flutter.bat'
if (!(Test-Path -LiteralPath $flutter)) { throw '请先按 docs/开发与验证.md 安装本地 Flutter 工具链。' }
# Directory junctions avoid requiring Windows Developer Mode for plugin links.
$pluginsFile = Join-Path $projectRoot '.flutter-plugins-dependencies'
if (Test-Path -LiteralPath $pluginsFile) {
  $plugins = Get-Content -LiteralPath $pluginsFile -Raw | ConvertFrom-Json
  $linkRoot = Join-Path $projectRoot 'windows/flutter/ephemeral/.plugin_symlinks'
  New-Item -ItemType Directory -Path $linkRoot -Force | Out-Null
  foreach ($plugin in $plugins.plugins.windows) {
    $linkPath = Join-Path $linkRoot $plugin.name
    if (!(Test-Path -LiteralPath $linkPath)) { New-Item -ItemType Junction -Path $linkPath -Target $plugin.path | Out-Null }
  }
}
& $flutter @FlutterArgs
exit $LASTEXITCODE
