$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
Set-Location $projectRoot
$javaHomeFile = Join-Path $projectRoot '.local/java-home.txt'
$javaRoot = if (Test-Path -LiteralPath $javaHomeFile) { (Get-Content -LiteralPath $javaHomeFile -Raw).Trim() } else { $env:JAVA_HOME }
if (!$javaRoot) { throw '请配置 JAVA_HOME 或 .local/java-home.txt（JDK 17 以上）。' }
if (!(Test-Path -LiteralPath (Join-Path $javaRoot 'bin/jlink.exe'))) { throw 'Android 构建需要包含 jlink 的完整 JDK，不能使用精简 JRE/JBR。请检查 .local/java-home.txt。' }
$keyFile = Join-Path $projectRoot '.local/howdoi-release.jks'
$configFile = Join-Path $projectRoot '.local/release-signing.properties'
if (!(Test-Path -LiteralPath $keyFile) -and !(Test-Path -LiteralPath $configFile)) {
  New-Item -ItemType Directory -Path (Join-Path $projectRoot '.local') -Force | Out-Null
  $passwordBytes = New-Object byte[] 32
  [System.Security.Cryptography.RandomNumberGenerator]::Fill($passwordBytes)
  $env:HOWDOI_KEY_PASSWORD = [Convert]::ToBase64String($passwordBytes)
  try {
    & (Join-Path $javaRoot 'bin/keytool.exe') -genkeypair -keystore $keyFile -storepass:env HOWDOI_KEY_PASSWORD -keypass:env HOWDOI_KEY_PASSWORD -alias howdoi -keyalg RSA -keysize 2048 -validity 10000 -dname 'CN=HowDoI' -storetype JKS
    if ($LASTEXITCODE -ne 0) { throw '签名生成失败' }
    @("storeFile=../.local/howdoi-release.jks", "storePassword=$env:HOWDOI_KEY_PASSWORD", 'keyAlias=howdoi', "keyPassword=$env:HOWDOI_KEY_PASSWORD") | Set-Content -LiteralPath $configFile -Encoding ascii
  } finally { Remove-Item Env:\HOWDOI_KEY_PASSWORD }
}
if (!(Test-Path -LiteralPath $keyFile) -or !(Test-Path -LiteralPath $configFile)) { throw '签名文件不完整。请恢复原签名备份，不要重新生成密钥。' }
& "$PSScriptRoot/Flutter.ps1" build apk --release --target-platform android-arm64
if ($LASTEXITCODE -ne 0) { throw 'Android 构建失败' }
New-Item -ItemType Directory -Path dist -Force | Out-Null
Copy-Item -LiteralPath build/app/outputs/flutter-apk/app-release.apk -Destination dist/HowDoI-0.1.0-android-arm64.apk -Force
