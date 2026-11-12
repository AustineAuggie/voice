#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$SourceDirectory = $PSScriptRoot,
    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'Programs\Voice'),
    [switch]$DesktopShortcut,
    [switch]$NoShortcuts,
    [switch]$NoLaunch
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Package([string]$Directory) {
    $manifestPath = Join-Path $Directory 'voice-package.json'
    if (!(Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'This is not a built Voice Windows package. Download the Windows ZIP from Releases and extract it first.' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.product -ne 'Voice.Windows' -or $manifest.schema -ne 1 -or $manifest.architecture -ne 'x64') { throw 'Unrecognised Voice package manifest.' }
    $prefix = [IO.Path]::GetFullPath($Directory).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $seen = @{}
    foreach ($entry in $manifest.files) {
        $relative = [string]$entry.path
        if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or $relative.Contains(':') -or $relative -match '(^|[\\/])\.\.([\\/]|$)') { throw 'Unsafe path in package manifest.' }
        $path = [IO.Path]::GetFullPath((Join-Path $Directory $relative))
        if (!$path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or $seen.ContainsKey($relative)) { throw 'Invalid or repeated package path.' }
        $seen[$relative] = $true
        $item = Get-Item -LiteralPath $path -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Unsupported package item: $relative" }
        if ($item.Length -ne [long]$entry.size -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.sha256) { throw "Package integrity check failed: $relative. Extract a fresh release ZIP." }
    }
    foreach ($item in Get-ChildItem -LiteralPath $Directory -Force -Recurse) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Links are not allowed inside an install package.' }
        if (!$item.PSIsContainer) {
            $relative = $item.FullName.Substring($prefix.Length).Replace('\', '/')
            if ($relative -ne 'voice-package.json' -and !$seen.ContainsKey($relative)) { throw "Unexpected file in package: $relative. Extract a fresh release ZIP before installing." }
        }
    }
    foreach ($required in @('Voice.exe', 'engines/localvoice-speech.exe', 'engines/localvoice-editor.exe', 'engines/localvoice-diarizer.exe')) {
        if (!$seen.ContainsKey($required)) { throw "Package is missing $required." }
    }
    return $manifest
}

if (![Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { throw 'This package is for Intel/AMD 64-bit Windows. Windows ARM is not included.' }
$source = [IO.Path]::GetFullPath($SourceDirectory).TrimEnd('\', '/')
$destination = [IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\', '/')
if ($source -eq $destination -or $source.StartsWith($destination + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Run this installer from a newly extracted download, not from the installed app folder.' }
$manifest = Assert-Package $source
$parent = Split-Path -Parent $destination
if ([string]::IsNullOrWhiteSpace($parent)) { throw 'Choose a normal app installation folder.' }
New-Item -ItemType Directory -Path $parent -Force | Out-Null
if (Test-Path -LiteralPath $destination) {
    $existingManifest = Join-Path $destination 'voice-package.json'
    if (!(Test-Path -LiteralPath $existingManifest -PathType Leaf)) { throw 'The destination already exists and is not a recognised Voice installation. It was left unchanged.' }
    $existing = Get-Content -LiteralPath $existingManifest -Raw | ConvertFrom-Json
    if ($existing.product -ne 'Voice.Windows' -or $existing.schema -ne 1) { throw 'The existing destination belongs to another application. It was left unchanged.' }
    foreach ($process in @(Get-Process -Name Voice -ErrorAction SilentlyContinue)) {
        try { $processPath = $process.Path } catch { $processPath = $null }
        if ($processPath -and $processPath.StartsWith($destination + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Close Voice, finish any recording, and run the installer again.' }
    }
}
$stage = Join-Path $parent ('.Voice-install-' + [Guid]::NewGuid().ToString('N'))
$backup = $destination + '.previous-' + [Guid]::NewGuid().ToString('N')
$movedOld = $false
$installed = $false
try {
    New-Item -ItemType Directory -Path $stage | Out-Null
    Get-ChildItem -LiteralPath $source -Force | Copy-Item -Destination $stage -Recurse -Force
    Assert-Package $stage | Out-Null
    if (Test-Path -LiteralPath $destination) { Move-Item -LiteralPath $destination -Destination $backup; $movedOld = $true }
    try { Move-Item -LiteralPath $stage -Destination $destination; $installed = $true }
    catch {
        if ($movedOld -and !(Test-Path -LiteralPath $destination)) { Move-Item -LiteralPath $backup -Destination $destination; $movedOld = $false }
        throw
    }
} finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}
if (!$installed) { throw 'Installation did not complete.' }

if (!$NoShortcuts) {
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcutFolders = @([Environment]::GetFolderPath('Programs'))
        if ($DesktopShortcut) { $shortcutFolders += [Environment]::GetFolderPath('DesktopDirectory') }
        foreach ($folder in $shortcutFolders) {
            if ([string]::IsNullOrWhiteSpace($folder)) { continue }
            $shortcutPath = Join-Path $folder 'Voice.lnk'
            $shortcut = $shell.CreateShortcut($shortcutPath)
            if ((Test-Path -LiteralPath $shortcutPath) -and $shortcut.TargetPath -ne (Join-Path $destination 'Voice.exe')) { Write-Warning "An unrelated Voice shortcut exists at $shortcutPath; it was retained."; continue }
            $shortcut.TargetPath = Join-Path $destination 'Voice.exe'
            $shortcut.WorkingDirectory = $destination
            $shortcut.Description = 'Voice - local dictation and meeting notes'
            $shortcut.Save()
        }
    } catch { Write-Warning "Voice is installed, but shortcuts could not be created: $($_.Exception.Message)" }
}
Write-Output "Installed Voice $($manifest.version) at $destination"
if ($movedOld) { Write-Output "Previous application retained at $backup" }
Write-Output 'Models, recordings and settings under LocalAppData\Voice were left unchanged.'
if (!$NoLaunch) { Start-Process -FilePath (Join-Path $destination 'Voice.exe') -WorkingDirectory $destination }
