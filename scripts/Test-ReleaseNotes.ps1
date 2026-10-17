$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path $root ('work/release-docs-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$fixture/scripts" -Force | Out-Null
Copy-Item "$PSScriptRoot/Write-ReleaseNotes.ps1" "$fixture/scripts/Write-ReleaseNotes.ps1"
"name: release_fixture`nversion: 9.8.7+65" | Set-Content "$fixture/pubspec.yaml"
'<!-- release-version: 9.8.7+65 -->' | Set-Content "$fixture/README.md"
'<!-- release-version: 9.8.6+64 -->' | Set-Content "$fixture/RELEASE_NOTES.md"
$rejected = $false
try { & "$fixture/scripts/Write-ReleaseNotes.ps1" -CheckOnly } catch { $rejected = $true }
if (!$rejected -or (Test-Path "$fixture/dist")) { throw '过期说明未阻止发布' }
'<!-- release-version: 9.8.7+65 -->' | Set-Content "$fixture/RELEASE_NOTES.md"
& "$fixture/scripts/Write-ReleaseNotes.ps1" -CheckOnly
if (Test-Path "$fixture/dist") { throw '预检查不应生成文件' }
& "$fixture/scripts/Write-ReleaseNotes.ps1"
if ((Get-Content "$fixture/dist/HowDoI-9.8.7-release-notes.md" -Raw) -ne (Get-Content "$fixture/RELEASE_NOTES.md" -Raw)) { throw '发布说明内容不一致' }
'<!-- release-version: 9.8.6+64 -->' | Set-Content "$fixture/README.md"
$rejected = $false
try { & "$fixture/scripts/Write-ReleaseNotes.ps1" -CheckOnly } catch { $rejected = $true }
if (!$rejected) { throw '过期 README 未阻止发布' }
Write-Output 'PASS: 旧 README / 说明阻止打包，预检查无输出副作用，正确版本生成对应文件。'
