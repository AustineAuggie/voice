#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackageDirectory)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('Voice install checks é ' + [Guid]::NewGuid().ToString('N'))
$destination = Join-Path $testRoot 'Programs/Voice'
$source = Join-Path $testRoot 'Download'
$checks = 0
function Assert([bool]$Condition, [string]$Message) {
    if (!$Condition) { throw "Installer check failed: $Message" }
    $script:checks++
}
function Install([string]$From, [string]$To) {
    & (Join-Path $From 'install.ps1') -SourceDirectory $From -InstallDirectory $To -NoLaunch -NoShortcuts
}
try {
    New-Item -ItemType Directory -Path $source -Force | Out-Null
    Get-ChildItem -LiteralPath $PackageDirectory -Force | Copy-Item -Destination $source -Recurse -Force
    $unrelatedData = Join-Path $testRoot 'Voice/Meetings/saved-note.txt'
    New-Item -ItemType Directory -Path (Split-Path -Parent $unrelatedData) -Force | Out-Null
    'Retain this meeting.' | Set-Content -LiteralPath $unrelatedData
    $dataHash = (Get-FileHash -LiteralPath $unrelatedData).Hash
    Install $source $destination
    Assert (Test-Path -LiteralPath (Join-Path $destination 'Voice.exe')) 'Fresh install creates the executable.'
    $before = (Get-FileHash -LiteralPath (Join-Path $destination 'Voice.exe')).Hash
    $expected = (Get-FileHash -LiteralPath (Join-Path $source 'Voice.exe')).Hash
    Assert ($before -eq $expected) 'Installed executable bytes match the built package.'
    Install $source $destination
    $backups = @(Get-ChildItem -LiteralPath (Split-Path -Parent $destination) -Directory -Filter 'Voice.previous-*')
    Assert ($backups.Count -eq 1) 'Upgrade retains exactly one previous installation.'
    Assert ((Get-FileHash -LiteralPath (Join-Path $backups[0].FullName 'Voice.exe')).Hash -eq $before) 'Backup retains the previous app bytes.'
    Assert ((Get-FileHash -LiteralPath $unrelatedData).Hash -eq $dataHash) 'Separate saved meeting is unchanged.'

    $unrelated = Join-Path $testRoot 'Programs/Unrelated'
    New-Item -ItemType Directory -Path $unrelated -Force | Out-Null
    'Other application' | Set-Content -LiteralPath (Join-Path $unrelated 'keep.txt')
    $rejected = $false
    try { Install $source $unrelated } catch { $rejected = $true }
    Assert $rejected 'Unrecognised destination is refused.'
    Assert ((Get-Content -LiteralPath (Join-Path $unrelated 'keep.txt') -Raw).Trim() -eq 'Other application') 'Unrecognised destination contents remain.'

    [IO.File]::AppendAllText((Join-Path $source 'README-Windows.md'), "`nCorrupted after packaging.")
    $rejected = $false
    try { Install $source $destination } catch { $rejected = $true }
    Assert $rejected 'Corrupt download is refused before replacement.'
    Assert ((Get-FileHash -LiteralPath (Join-Path $destination 'Voice.exe')).Hash -eq $before) 'Rejected download leaves installed application untouched.'
    Copy-Item -LiteralPath (Join-Path $PackageDirectory 'README-Windows.md') -Destination (Join-Path $source 'README-Windows.md') -Force

    'unexpected executable' | Set-Content -LiteralPath (Join-Path $source 'unexpected.exe')
    $rejected = $false
    try { Install $source $destination } catch { $rejected = $true }
    Assert $rejected 'Unlisted file inside package is refused.'
    Remove-Item -LiteralPath (Join-Path $source 'unexpected.exe')

    $manifestPath = Join-Path $source 'voice-package.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $manifest.files[0].path = '../outside.txt'
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath
    $rejected = $false
    try { Install $source $destination } catch { $rejected = $true }
    Assert $rejected 'A traversal path in a package manifest is refused.'
    Assert ((Get-FileHash -LiteralPath (Join-Path $destination 'Voice.exe')).Hash -eq $before) 'Traversal rejection leaves installed application untouched.'
    Assert (@(Get-ChildItem -LiteralPath (Split-Path -Parent $destination) -Directory -Filter '.Voice-install-*').Count -eq 0) 'No temporary install directories remain.'
    Write-Output "Passed $checks Windows installer integrity and upgrade checks."
} finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
