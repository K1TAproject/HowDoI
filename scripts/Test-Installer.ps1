$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
Set-Location $projectRoot
$version = ([regex]::Match((Get-Content pubspec.yaml -Raw), '(?m)^version:\s*(\d+\.\d+\.\d+)')).Groups[1].Value
$setup = Join-Path $projectRoot "dist/HowDoI-$version-windows-x64-setup.exe"
$registry = 'HKCU:\Software\K1TAproject\HowDoI'
$uninstallRegistry = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\HowDoI'
$desktopLink = Join-Path ([Environment]::GetFolderPath('Desktop')) 'HowDoI.lnk'
$menuLink = Join-Path ([Environment]::GetFolderPath('Programs')) 'HowDoI.lnk'
# Do not disturb an existing installation, its shortcuts, or a running user session.
foreach ($existing in @($registry,$uninstallRegistry,$desktopLink,$menuLink)) {
  if (Test-Path -LiteralPath $existing) { throw "已有安装或快捷方式，不执行覆盖测试：$existing" }
}
if (Get-Process howdoi -ErrorAction SilentlyContinue) { throw 'HowDoI 正在运行，不自动关闭用户窗口' }
$testRoot = Join-Path $projectRoot ('work/installer-smoke-' + [guid]::NewGuid().ToString('N'))
$install = Join-Path $testRoot '安装 目录'
New-Item -ItemType Directory -Path $install -Force | Out-Null
$sentinel = Join-Path $install 'user-note.txt'
'keep user file' | Set-Content -LiteralPath $sentinel
$release = Join-Path $projectRoot 'build/windows/x64/runner/Release'
$uninstaller = Join-Path $install 'Uninstall.exe'
try {
  for ($attempt=1; $attempt -le 2; $attempt++) {
    $process = Start-Process -FilePath $setup -ArgumentList '/S',"/D=$install" -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "安装/重装失败：$($process.ExitCode)" }
    foreach ($file in Get-ChildItem -LiteralPath $release -File -Recurse) {
      $relative = $file.FullName.Substring($release.Length + 1)
      $installed = Join-Path $install $relative
      if (!(Test-Path -LiteralPath $installed) -or (Get-FileHash -LiteralPath $installed).Hash -ne (Get-FileHash -LiteralPath $file.FullName).Hash) { throw "安装文件不一致：$relative" }
    }
    if ((Get-ItemProperty -LiteralPath $registry).InstallDir -ne $install) { throw '安装位置注册错误' }
    foreach ($link in @($desktopLink,$menuLink)) {
      if (!(Test-Path -LiteralPath $link)) { throw "快捷方式缺失：$link" }
      $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($link)
      if ($shortcut.TargetPath -ne (Join-Path $install 'howdoi.exe')) { throw '快捷方式目标错误' }
    }
    if ((Get-Content -LiteralPath $sentinel -Raw).Trim() -ne 'keep user file') { throw '用户文件被改动' }
    Write-Output "安装/同版重装 $attempt：文件哈希、注册信息、快捷方式、用户文件均通过"
  }
  $probeDB = Join-Path $testRoot 'probe.db'
  [IO.File]::WriteAllBytes($probeDB, [byte[]]@())
  $ready = Join-Path $testRoot 'ready'
  $process = Start-Process -FilePath (Join-Path $install 'howdoi.exe') -ArgumentList '--update-probe',"`"$probeDB`"","`"$ready`"" -WorkingDirectory $install -WindowStyle Hidden -PassThru
  if (!$process.WaitForExit(30000)) { $process.Kill(); $process.WaitForExit(); throw '安装后试启动超时' }
  if ($process.ExitCode -ne 0 -or !(Test-Path -LiteralPath $ready)) { throw '安装后试启动失败' }
  Write-Output '安装后的实际 EXE 使用独立数据库启动成功'
} finally {
  if (Test-Path -LiteralPath $uninstaller) {
    $process = Start-Process -FilePath $uninstaller -ArgumentList '/S' -WindowStyle Hidden -Wait -PassThru
    for ($i=0; $i -lt 100 -and (Test-Path -LiteralPath $uninstaller); $i++) { Start-Sleep -Milliseconds 100 }
  }
}
foreach ($removed in @($registry,$uninstallRegistry,$desktopLink,$menuLink,$uninstaller,(Join-Path $install 'howdoi.exe'))) {
  if (Test-Path -LiteralPath $removed) { throw "卸载未完成：$removed" }
}
if ((Get-Content -LiteralPath $sentinel -Raw).Trim() -ne 'keep user file' -or !(Test-Path -LiteralPath $probeDB)) { throw '卸载误删用户文件或数据' }
Write-Output "卸载通过：注册信息、快捷方式和程序已删除，额外文件与独立数据库保留。证据目录：$testRoot"
