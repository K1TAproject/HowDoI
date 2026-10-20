param([Parameter(Mandatory=$true)][string]$ReleaseDir)
$ErrorActionPreference = 'Stop'
$allowed = @(
  'concrt140.dll'
  'dartjni.dll'
  'data/app.so'
  'data/flutter_assets/AssetManifest.bin'
  'data/flutter_assets/FontManifest.json'
  'data/flutter_assets/NOTICES.Z'
  'data/flutter_assets/NativeAssetsManifest.json'
  'data/flutter_assets/assets/windows-update.ps1'
  'data/flutter_assets/fonts/MaterialIcons-Regular.otf'
  'data/flutter_assets/packages/flutter_map/lib/assets/flutter_map_logo.png'
  'data/flutter_assets/pubspec.yaml'
  'data/flutter_assets/shaders/ink_sparkle.frag'
  'data/flutter_assets/shaders/stretch_effect.frag'
  'data/icudtl.dat'
  'flutter_windows.dll'
  'howdoi.exe'
  'msvcp140.dll'
  'msvcp140_1.dll'
  'msvcp140_2.dll'
  'msvcp140_atomic_wait.dll'
  'msvcp140_codecvt_ids.dll'
  'sqlite3.dll'
  'url_launcher_windows_plugin.dll'
  'vccorlib140.dll'
  'vcruntime140.dll'
  'vcruntime140_1.dll'
  'vcruntime140_threads.dll'
)
$root = (Resolve-Path -LiteralPath $ReleaseDir).Path
$files = @(Get-ChildItem -LiteralPath $root -Recurse -File)
foreach ($file in $files) {
  $relative = $file.FullName.Substring($root.Length + 1).Replace('\','/')
  if ($relative -notin $allowed -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Unexpected release payload: $relative" }
}
foreach ($relative in $allowed) {
  if (!(Test-Path -LiteralPath (Join-Path $root $relative) -PathType Leaf)) { throw "Missing release payload: $relative" }
}
