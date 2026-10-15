param([string]$Job, [switch]$Inspect)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)

function Get-UpdateHash([string]$path) {
    $stream = [IO.File]::OpenRead($path)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    finally { $stream.Dispose(); $algorithm.Dispose() }
}

function Get-InstallCandidates {
    $paths = @()
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, $view)
        $key = $base.OpenSubKey('Software\K1TAproject\HowDoI')
        if ($key) { $paths += $key.GetValue('InstallDir'); $key.Close() }
        $base.Close()
    }
    $shell = New-Object -ComObject WScript.Shell
    foreach ($folder in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))) {
        $link = Join-Path $folder 'HowDoI.lnk'
        if (Test-Path -LiteralPath $link) {
            $target = $shell.CreateShortcut($link).TargetPath
            if ($target -and (Split-Path $target -Leaf) -eq 'howdoi.exe') { $paths += Split-Path $target -Parent }
        }
    }
    @($paths | Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $_ 'Uninstall.exe')) -and (Test-Path -LiteralPath (Join-Path $_ 'howdoi.exe')) } | Select-Object -Unique)
}

function Write-UpdateStatus($job, $state, $message) {
    @{ state = $state; message = $message; version = $job.version; target = $job.target } |
        ConvertTo-Json | Set-Content -LiteralPath $job.result -Encoding UTF8
}

function Start-Installer($job) {
    # /D must be last and unquoted, per NSIS command-line parsing. No shell evaluates it.
    $process = Start-Process -FilePath $job.package -ArgumentList '/S', ('/D=' + $job.target) -WindowStyle Hidden -PassThru -Wait
    return $process.ExitCode
}

function Invoke-InstallerUpdate($job, $desktop, $menu, $registry, $installRegistry = 'HKCU:\Software\K1TAproject\HowDoI') {
    $target = [IO.Path]::GetFullPath($job.target).TrimEnd('\')
    if ($target -ne $job.target -or !(Test-Path -LiteralPath (Join-Path $target 'Uninstall.exe'))) { throw 'Invalid installed directory' }
    if ((Get-UpdateHash $job.package) -ne $job.sha) { throw 'Installer checksum failed; installation unchanged' }
    $packageVersion = (Get-Item -LiteralPath $job.package).VersionInfo.ProductVersion
    if (($packageVersion -split '\+')[0] -ne ($job.version -split '\+')[0]) { throw 'Installer version mismatch' }
    # All rollback operations stay in this exact installation or the unique transaction folder.
    if ([IO.Path]::GetFullPath($job.result).StartsWith($target + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Update workspace must be outside the installation' }
    $backup = Join-Path (Split-Path $job.result -Parent) ('rollback-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $backup | Out-Null
    $originals = @(Get-ChildItem -LiteralPath $target -File -Recurse | ForEach-Object { $_.FullName.Substring($target.Length + 1) })
    if (Get-ChildItem -LiteralPath $target -Recurse -Attributes ReparsePoint) { throw 'Installation contains links; update stopped before changing files' }
    foreach ($relative in $originals) {
        $copy = Join-Path $backup ('files\' + $relative)
        New-Item -ItemType Directory -Path (Split-Path $copy -Parent) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $target $relative) -Destination $copy
    }
    $links = @{}
    foreach ($link in @($desktop, $menu)) {
        $links[$link] = if (Test-Path -LiteralPath $link) { [IO.File]::ReadAllBytes($link) } else { $null }
    }
    $priorRegistry = @{}
    foreach ($key in @($registry, $installRegistry)) {
        if (Test-Path -LiteralPath $key) {
            $values = @{}
            $rk = Get-Item -LiteralPath $key
            foreach ($name in $rk.GetValueNames()) { $values[$name] = $rk.GetValue($name) }
            $priorRegistry[$key] = $values
        }
    }
    try {
        Write-UpdateStatus $job 'installing' 'Installing into original directory'
        $code = Start-Installer $job
        if ($code -ne 0) { throw "Installer exited with code $code" }
        $exe = Join-Path $target 'howdoi.exe'
        if ((Get-Item -LiteralPath $exe).VersionInfo.ProductVersion -ne $packageVersion) { throw 'Installed executable version mismatch' }
        $shell = New-Object -ComObject WScript.Shell
        foreach ($link in @($desktop, $menu)) {
            if (!(Test-Path -LiteralPath $link) -or $shell.CreateShortcut($link).TargetPath -ne $exe) { throw 'Shortcut target verification failed' }
        }
        # Validate compatibility using a disposable copy, never the live database.
        $probe = Join-Path $backup 'probe.db'
        Copy-Item -LiteralPath $job.databaseBackup -Destination $probe
        $ready = Join-Path $backup 'ready'
        $process = Start-Process -FilePath $exe -ArgumentList '--update-probe', ('"' + $probe + '"'), ('"' + $ready + '"') -WindowStyle Hidden -PassThru
        if (!$process.WaitForExit(30000)) { $process.Kill(); $process.WaitForExit(); throw 'Updated executable probe timed out' }
        if ($process.ExitCode -ne 0 -or !(Test-Path -LiteralPath $ready)) { throw 'Updated executable probe failed' }
        Write-UpdateStatus $job 'completed' 'Installer, original directory version, shortcuts and data-copy probe verified'
        return $exe
    } catch {
        $reason = $_.Exception.Message
        try {
            foreach ($file in Get-ChildItem -LiteralPath $target -File -Recurse) {
                $relative = $file.FullName.Substring($target.Length + 1)
                if ($relative -notin $originals) { Remove-Item -LiteralPath $file.FullName -Force }
            }
            foreach ($relative in $originals) { Copy-Item -LiteralPath (Join-Path $backup ('files\' + $relative)) -Destination (Join-Path $target $relative) -Force }
            foreach ($link in $links.Keys) {
                if ($null -ne $links[$link]) { [IO.File]::WriteAllBytes($link, $links[$link]) }
                elseif (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link }
            }
            foreach ($key in @($registry, $installRegistry)) {
                if (!$priorRegistry.ContainsKey($key) -and (Test-Path -LiteralPath $key)) { Remove-Item -LiteralPath $key }
            }
            foreach ($key in $priorRegistry.Keys) {
                foreach ($name in $priorRegistry[$key].Keys) { Set-ItemProperty -LiteralPath $key -Name $name -Value $priorRegistry[$key][$name] }
            }
            Write-UpdateStatus $job 'failed' "$reason; previous installation restored"
        } catch {
            Write-UpdateStatus $job 'failed' "$reason; rollback incomplete: $($_.Exception.Message); backup retained at $backup"
        }
        throw $reason
    }
}

if ($Inspect) {
    ConvertTo-Json -InputObject @(Get-InstallCandidates) -Compress
} elseif ($Job) {
    $jobData = Get-Content -LiteralPath $Job -Raw -Encoding UTF8 | ConvertFrom-Json
    try {
        Write-UpdateStatus $jobData 'waiting' 'Waiting for current application to close'
        [IO.File]::WriteAllText($jobData.ready, 'ready')
        $parent = Get-Process -Id $jobData.parentId -ErrorAction SilentlyContinue
        if ($parent -and !$parent.WaitForExit(60000)) { throw 'Current application did not close; installation not started' }
        $exe = Invoke-InstallerUpdate $jobData (Join-Path ([Environment]::GetFolderPath('Desktop')) 'HowDoI.lnk') (Join-Path ([Environment]::GetFolderPath('Programs')) 'HowDoI.lnk') 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\HowDoI'
        Start-Process -FilePath $exe
    } catch {
        if (!(Test-Path -LiteralPath $jobData.result) -or ((Get-Content -LiteralPath $jobData.result -Raw | ConvertFrom-Json).state -ne 'failed')) { Write-UpdateStatus $jobData 'failed' $_.Exception.Message }
        # Report failure without relying on a successful new launch. The result remains visible in About.
        $shell = New-Object -ComObject WScript.Shell
        $shell.Popup("HowDoI update failed. Your travel data has not been replaced.`n$($_.Exception.Message)", 0, 'HowDoI', 16) | Out-Null
        if (!$parent -or $parent.HasExited) { Start-Process -FilePath $jobData.currentExe }
        exit 1
    }
}
