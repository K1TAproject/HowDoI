param([Parameter(Mandatory=$true)][string]$Database)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
. "$root/assets/windows-update.ps1"
$testRoot = Join-Path $root ('work/update-install-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$installKey = 'Software\K1TAproject\HowDoI-Test-' + [guid]::NewGuid().ToString('N')
$uninstallKey = $installKey + '\Uninstall'
$desktop = Join-Path $testRoot 'Desktop/HowDoI.lnk'
$menu = Join-Path $testRoot 'Programs/HowDoI.lnk'
$target = Join-Path $testRoot 'Custom 安装目录'
$old = Join-Path $testRoot 'old-payload'
Expand-Archive -LiteralPath 'dist/HowDoI-0.1.5-windows-x64.zip' -DestinationPath $old
$currentFull = ([regex]::Match((Get-Content pubspec.yaml -Raw), '(?m)^version:\s*([0-9.+]+)')).Groups[1].Value
$currentVersion = ($currentFull -split '\+')[0]
$currentNumeric = $currentFull.Replace('+','.')
$originalSetup = Join-Path $testRoot 'old-setup.exe'
$newSetup = Join-Path $testRoot 'new-setup.exe'
function Compile-Isolated($payload, $version, $full, $numeric, $output) {
    & "$root/.tools/nsis/makensis.exe" /V2 /INPUTCHARSET UTF8 "/DPROJECT_ROOT=$root" "/DRELEASE_DIR=$payload" "/DUNINSTALL_FILES=$root\work\installer\uninstall-files.nsh" "/DVERSION=$version" "/DFULL_VERSION=$full" "/DNUMERIC_VERSION=$numeric" "/DOUTPUT_FILE=$output" "/DISOLATED_ROOT=$testRoot" "/DINSTALL_KEY=$installKey" "/DUNINSTALL_KEY=$uninstallKey" "$root/scripts/windows-installer.nsi"
    if ($LASTEXITCODE -ne 0) { throw 'Isolated installer compile failed' }
}
function Assert($condition, $message) { if (!$condition) { throw $message } }
try {
    Compile-Isolated $old '0.1.5' '0.1.5+6' '0.1.5.6' $originalSetup
    Compile-Isolated "$root\build\windows\x64\runner\Release" $currentVersion $currentFull $currentNumeric $newSetup
    $process = Start-Process -FilePath $originalSetup -ArgumentList '/S',("/D=$target") -WindowStyle Hidden -Wait -PassThru
    Assert ($process.ExitCode -eq 0) 'Old installation failed'
    $exe = Join-Path $target 'howdoi.exe'
    Assert ((Get-Item -LiteralPath $exe).VersionInfo.ProductVersion -eq '0.1.5+6') 'Old version incorrect'
    $extra = Join-Path $target 'user-note.txt'
    'keep extra file' | Set-Content -LiteralPath $extra
    $dataHash = (Get-UpdateHash $Database)
    $taskJob = [pscustomobject]@{
        target=$target; package=$newSetup; version=$currentVersion; sha=(Get-UpdateHash $newSetup)
        databaseBackup=$Database; result=(Join-Path $testRoot 'result.json')
    }
    $installedExe = Invoke-InstallerUpdate $taskJob $desktop $menu "HKCU:\$uninstallKey" "HKCU:\$installKey"
    Assert ((Get-Item -LiteralPath $installedExe).VersionInfo.ProductVersion -eq $currentFull) 'New version incorrect'
    Assert ((Get-Content -LiteralPath $taskJob.result -Raw | ConvertFrom-Json).state -eq 'completed') 'Completion not verified'
    Assert ((Get-UpdateHash $Database) -eq $dataHash) 'Fixture database changed'
    Assert ((Get-Content -LiteralPath $extra -Raw).Trim() -eq 'keep extra file') 'Extra user file changed'
    $shell = New-Object -ComObject WScript.Shell
    foreach ($link in @($desktop,$menu)) {
        $shortcut = $shell.CreateShortcut($link)
        Assert ($shortcut.TargetPath -eq $exe) 'Shortcut points elsewhere'
        Assert ((Get-Item -LiteralPath $shortcut.TargetPath).VersionInfo.ProductVersion -eq $currentFull) 'Shortcut opens old version'
        # Launch through the shortcut itself, with a disposable probe DB, then restore its normal arguments.
        $ready = Join-Path $testRoot ([guid]::NewGuid().ToString('N'))
        $dbCopy = $ready + '.db'
        Copy-Item -LiteralPath $Database -Destination $dbCopy
        $shortcut.Arguments = '--update-probe "' + $dbCopy + '" "' + $ready + '"'
        $shortcut.Save()
        Start-Process -FilePath $link -WindowStyle Hidden -Wait
        for ($i=0; $i -lt 300 -and !(Test-Path -LiteralPath $ready); $i++) { Start-Sleep -Milliseconds 100 }
        $shortcut.Arguments = ''; $shortcut.Save()
        Assert (Test-Path -LiteralPath $ready) 'Shortcut launch did not acknowledge'
    }
    Write-Output "PASS: old installed 0.1.5 -> $currentVersion, custom directory, Desktop and Start Menu shortcut launches, data unchanged"
    $prior = (Get-UpdateHash $exe)
    $savedStart = ${function:Start-Installer}
    foreach ($failure in @('cancel','partial','false-success')) {
        $script:failure = $failure
        function Start-Installer($taskJob) {
            if ($script:failure -eq 'partial') { [IO.File]::WriteAllText((Join-Path $taskJob.target 'howdoi.exe'), 'partial overwrite'); return 17 }
            if ($script:failure -eq 'cancel') { return 1 }
            # Exit 0 is not sufficient: break a shortcut and require rollback.
            Remove-Item -LiteralPath $script:menu
            return 0
        }
        $failed = $false
        try { Invoke-InstallerUpdate $taskJob $desktop $menu "HKCU:\$uninstallKey" "HKCU:\$installKey" | Out-Null } catch { $failed = $true }
        Assert $failed "Failure $failure not reported"
        Assert ((Get-UpdateHash $exe) -eq $prior) "Failure $failure did not restore original"
        Assert ((Get-Content -LiteralPath $taskJob.result -Raw | ConvertFrom-Json).state -eq 'failed') 'False completion'
        Assert ($shell.CreateShortcut($menu).TargetPath -eq $exe) 'Link not restored'
        Write-Output "PASS: $failure -> failed status, program and shortcut restored"
    }
    ${function:Start-Installer} = $savedStart
    $taskJob.sha = '0' * 64
    $failed = $false
    try { Invoke-InstallerUpdate $taskJob $desktop $menu "HKCU:\$uninstallKey" "HKCU:\$installKey" | Out-Null } catch { $failed = $true }
    Assert $failed 'Invalid checksum accepted'
    Assert ((Get-UpdateHash $exe) -eq $prior) 'Checksum failure changed installation'
    Assert ((Get-UpdateHash $Database) -eq $dataHash) 'Data changed during failure tests'
    Write-Output 'PASS: install-time checksum failure leaves installation and database unchanged'
    Write-Output "Evidence: $testRoot"
} finally {
    # Remove only this run's unique test registry keys; keep files as verification evidence.
    if (Test-Path -LiteralPath "HKCU:\$installKey") { Remove-Item -LiteralPath "HKCU:\$installKey" -Recurse }
}
