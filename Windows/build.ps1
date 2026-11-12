#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Release')][string]$Configuration = 'Release',
    [ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version = '0.7.0',
    [string]$OutputDirectory = '',
    [switch]$SkipNative,
    [string]$NativeDirectory = '',
    [switch]$SkipInferenceSmoke
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (!$IsWindows -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') { throw 'Build the Windows x64 package on an Intel/AMD x64 Windows machine.' }
$root = Split-Path -Parent $PSScriptRoot
if (!$OutputDirectory) { $OutputDirectory = Join-Path $root 'dist-windows.noindex' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$stageRoot = Join-Path $OutputDirectory ('.stage-' + [Guid]::NewGuid().ToString('N'))
$name = "Voice-$Version-Windows-x64"
$appRoot = Join-Path $stageRoot $name
$archive = Join-Path $OutputDirectory ($name + '.zip')
if (Test-Path -LiteralPath $archive) { throw "Refusing to replace an existing package: $archive. Use a fresh OutputDirectory." }
function Invoke-Checked([scriptblock]$Command) { & $Command; if ($LASTEXITCODE -ne 0) { throw "Build command failed with exit code $LASTEXITCODE." } }
function Invoke-TimedProgram([string]$File, [string]$Arguments, [int]$Seconds = 60) {
    $process = Start-Process -FilePath $File -ArgumentList $Arguments -PassThru
    if (!$process.WaitForExit($Seconds * 1000)) { $process.Kill($true); throw "Startup check timed out: $File" }
    $process.Refresh()
    if ($process.ExitCode -ne 0) { throw "Startup check failed with exit $($process.ExitCode): $File" }
}
try {
    New-Item -ItemType Directory -Path $appRoot -Force | Out-Null
    Invoke-Checked { dotnet run --project (Join-Path $PSScriptRoot 'Voice.Core.Tests/Voice.Core.Tests.csproj') --configuration $Configuration }
    Invoke-Checked { dotnet publish (Join-Path $PSScriptRoot 'Voice.Windows/Voice.Windows.csproj') --configuration $Configuration --runtime win-x64 --self-contained true --output $appRoot -p:Version=$Version -p:PublishSingleFile=false -p:PublishTrimmed=false -p:DebugType=None -p:DebugSymbols=false }
    $engines = Join-Path $appRoot 'engines'
    if ($SkipNative) {
        if (!$NativeDirectory -or !(Test-Path -LiteralPath $NativeDirectory -PathType Container)) { throw '-SkipNative requires -NativeDirectory containing the previously built engines.' }
        New-Item -ItemType Directory -Path $engines -Force | Out-Null
        Get-ChildItem -LiteralPath $NativeDirectory -Force | Copy-Item -Destination $engines -Recurse -Force
    } else { & (Join-Path $PSScriptRoot 'build-native.ps1') -OutputDirectory $engines -Configuration $Configuration }
    foreach ($exe in @('Voice.exe', 'engines/localvoice-speech.exe', 'engines/localvoice-editor.exe', 'engines/localvoice-diarizer.exe')) {
        if (!(Test-Path -LiteralPath (Join-Path $appRoot $exe) -PathType Leaf)) { throw "Build omitted $exe." }
    }
    & (Join-Path $root 'Native/windows/Smoke.ps1') -EngineDirectory $engines
    if (!$SkipInferenceSmoke) {
        Invoke-Checked { python (Join-Path $PSScriptRoot 'tests/native_smoke.py') --engines $engines --cache (Join-Path $root '.build/windows-smoke') }
    }
    Invoke-TimedProgram (Join-Path $appRoot 'Voice.exe') '--smoke-test'
    # Synthetic UI-only previews are a separate review artifact, never part of
    # the application ZIP or a user's recordings/model store.
    $previewDirectory = Join-Path $OutputDirectory 'ui-preview'
    New-Item -ItemType Directory -Path $previewDirectory -Force | Out-Null
    Invoke-TimedProgram (Join-Path $appRoot 'Voice.exe') ("--render-preview `"$previewDirectory`"") 60
    if (@(Get-ChildItem -LiteralPath $previewDirectory -Filter '*.png' -File).Count -lt 5) { throw 'UI preview did not render all five review images.' }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'install.ps1'), (Join-Path $PSScriptRoot 'install.cmd') -Destination $appRoot
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'README.md') -Destination (Join-Path $appRoot 'README-Windows.md')
    Copy-Item -LiteralPath (Join-Path $root 'LICENSE'), (Join-Path $root 'THIRD-PARTY-NOTICES.txt') -Destination $appRoot
    $notices = Join-Path $appRoot 'Licences'
    New-Item -ItemType Directory -Path $notices -Force | Out-Null
    Get-ChildItem -Path (Join-Path $root 'Resources/*LICENSE*'), (Join-Path $root 'Resources/*NOTICE*'), (Join-Path $root 'Resources/*Notices*') -File | Sort-Object FullName -Unique | Copy-Item -Destination $notices
    if (Test-Path (Join-Path $PSScriptRoot 'NAudio-LICENSE.txt')) { Copy-Item (Join-Path $PSScriptRoot 'NAudio-LICENSE.txt') $notices }
    $files = @(Get-ChildItem -LiteralPath $appRoot -Recurse -File | Sort-Object FullName | ForEach-Object {
        [ordered]@{ path = $_.FullName.Substring($appRoot.Length + 1).Replace('\', '/'); size = $_.Length; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
    $manifest = [ordered]@{ schema = 1; product = 'Voice.Windows'; version = $Version; architecture = 'x64'; runtime = 'self-contained .NET 10'; files = $files }
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $appRoot 'voice-package.json') -Encoding utf8NoBOM
    & (Join-Path $PSScriptRoot 'tests/Installer.Tests.ps1') -PackageDirectory $appRoot
    Compress-Archive -LiteralPath $appRoot -DestinationPath $archive -CompressionLevel Optimal
    $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $name.zip" | Set-Content -LiteralPath ($archive + '.sha256') -Encoding utf8NoBOM
    Write-Output "Built $archive"
    Write-Output "SHA256 $hash"
} finally {
    if (Test-Path -LiteralPath $stageRoot) { Remove-Item -LiteralPath $stageRoot -Recurse -Force }
}
