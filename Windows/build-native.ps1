[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [ValidateSet('Release')][string]$Configuration = 'Release',
    [string]$CacheDirectory = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not [Environment]::Is64BitOperatingSystem -or $env:OS -ne 'Windows_NT') { throw 'Build native engines on Windows x64.' }
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $CacheDirectory) { $CacheDirectory = Join-Path $ProjectRoot '.build/windows-native' }
$CacheDirectory = [IO.Path]::GetFullPath($CacheDirectory)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force $CacheDirectory, $OutputDirectory | Out-Null
foreach ($tool in @('git', 'cmake', 'python', 'curl.exe')) { if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Missing build tool: $tool" } }

function Invoke-Checked([string]$Command, [string[]]$Arguments) {
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command failed with exit code $LASTEXITCODE" }
}
function Test-Hash([string]$Path, [string]$Expected) {
    return (Test-Path -LiteralPath $Path -PathType Leaf) -and ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $Expected)
}
function Get-Verified([string]$Url, [string]$Path, [string]$Expected) {
    if (Test-Hash $Path $Expected) { return }
    $temporary = "$Path.download"
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Write-Host "Downloading pinned speaker engine archive (attempt $attempt of 3)."
            Invoke-Checked 'curl.exe' @('--fail', '--location', '--silent', '--show-error',
                '--connect-timeout', '20', '--max-time', '180', '--output', $temporary, $Url)
            if (-not (Test-Hash $temporary $Expected)) { throw "Downloaded engine archive failed SHA-256 verification: $Url" }
            Move-Item -LiteralPath $temporary -Destination $Path -Force
            Write-Host "Speaker archive downloaded and SHA-256 verified."
            return
        } catch {
            if ($attempt -eq 3) { throw }
        }
    }
}
function Get-Engine([string]$Name, [string]$Url, [string]$Tag, [string]$Commit) {
    $directory = Join-Path $CacheDirectory $Name
    if (-not (Test-Path -LiteralPath (Join-Path $directory '.git'))) {
        Invoke-Checked 'git' @('clone', '--depth', '1', '--branch', $Tag, $Url, $directory)
    }
    $head = & git -C $directory rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $head -ne $Commit) { throw "Engine source is not the pinned version: $directory" }
    $changes = & git -C $directory status --porcelain --untracked-files=no
    if ($LASTEXITCODE -ne 0 -or $changes) { throw "Engine source contains local edits: $directory" }
    return $directory
}

# Official Visual Studio 2022 MT build, pinned by release asset SHA-256. No
# account or hosted inference is used. DLLs are placed beside the worker EXE.
$sdkName = 'sherpa-onnx-v2.0.1-win-x64-shared-MT-Release-no-tts-lib'
$archive = Join-Path $CacheDirectory "$sdkName.tar.bz2"
Get-Verified "https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.1/$sdkName.tar.bz2" $archive '21da6a8b92d63ca02ad41dbfc120012343aaaec2e5e02b14819c6b4f38004509'
Write-Host 'Extracting the verified speaker archive.'
Invoke-Checked 'python' @((Join-Path $PSScriptRoot 'extract-speaker-sdk.py'), $archive, $CacheDirectory)
Write-Host 'Speaker archive extracted.'
$sdkLib = Join-Path $CacheDirectory "$sdkName/lib"
$libraries = @{
    'sherpa-onnx-c-api.dll' = 'ee2af9f49b8fc5dae135ad20c0b955cbab90d17b79cc1ad0db91e03b24962f68'
    'sherpa-onnx-c-api.lib' = 'edf4b780d0ab4f0320d210f9cfc7e96e01d9b0dbee7234746f6cb6b422065997'
    'onnxruntime.dll' = '7f66f939a881baf4f46a2216496798edf4a1429878b646d12674aa62f27d8a25'
    'onnxruntime_providers_shared.dll' = '551d0e1fe4c227d8542314ba718d52f4379e0c7bfe729a37c59833a884e27b4d'
}
foreach ($name in $libraries.Keys) {
    $library = Join-Path $sdkLib $name
    if (-not (Test-Hash $library $libraries[$name])) { throw "Speaker library verification failed: $name" }
    if ($name.EndsWith('.dll')) { Copy-Item -LiteralPath $library -Destination $OutputDirectory -Force }
}

Write-Host 'Speaker runtime files verified. Building speech and editor engines.'
$SpeechSource = Get-Engine 'whisper-v1.7.6' 'https://github.com/ggml-org/whisper.cpp.git' 'v1.7.6' 'a8d002cfd879315632a579e73f0148d06959de36'
$EditorSource = Get-Engine 'llama-b5046' 'https://github.com/ggml-org/llama.cpp.git' 'b5046' '74d4f5b041ad837153b0e90fc864b8290e01d8d5'
$hasher = [Security.Cryptography.SHA256]::Create()
try { $sourceKey = ([BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($ProjectRoot)))).Replace('-', '').Substring(0, 12) }
finally { $hasher.Dispose() }
$common = @('-G', 'Visual Studio 17 2022', '-A', 'x64',
    '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded', '-DCMAKE_POLICY_DEFAULT_CMP0091=NEW',
    '-DCMAKE_C_FLAGS=/utf-8', '-DCMAKE_CXX_FLAGS=/utf-8 /EHsc',
    '-DGGML_NATIVE=OFF', '-DGGML_AVX=OFF', '-DGGML_AVX2=OFF', '-DGGML_AVX512=OFF',
    '-DGGML_AVX_VNNI=OFF', '-DGGML_FMA=OFF', '-DGGML_F16C=OFF', '-DGGML_SSE42=OFF', '-DGGML_BMI2=OFF',
    '-DGGML_OPENMP=OFF', '-DGGML_METAL=OFF', '-DGGML_CUDA=OFF', '-DGGML_VULKAN=OFF',
    '-DBUILD_SHARED_LIBS=OFF', '-DGGML_STATIC=ON', "-DJSON_INCLUDE=$SpeechSource/examples")
$jobs = [Math]::Max(1, [Math]::Min(4, [Environment]::ProcessorCount))
foreach ($engine in @('speech', 'editor')) {
    $source = if ($engine -eq 'speech') { $SpeechSource } else { $EditorSource }
    $build = Join-Path $CacheDirectory "build-$engine-$sourceKey"
    Invoke-Checked 'cmake' (@('-S', (Join-Path $ProjectRoot 'Native'), '-B', $build, "-DVOICE_ENGINE=$engine", "-DENGINE_SOURCE=$source") + $common)
    Invoke-Checked 'cmake' @('--build', $build, '--config', $Configuration, '--target', "localvoice-$engine", '--parallel', "$jobs")
    Copy-Item -LiteralPath (Join-Path $build "$Configuration/localvoice-$engine.exe") -Destination $OutputDirectory -Force
}

$diarizerBuild = Join-Path $CacheDirectory "build-diarizer-$sourceKey"
Invoke-Checked 'cmake' @('-S', (Join-Path $ProjectRoot 'Native/windows'), '-B', $diarizerBuild,
    '-G', 'Visual Studio 17 2022', '-A', 'x64', "-DSHERPA_LIBRARY_DIR=$sdkLib")
Invoke-Checked 'cmake' @('--build', $diarizerBuild, '--config', $Configuration, '--parallel', "$jobs")
Copy-Item -LiteralPath (Join-Path $diarizerBuild "$Configuration/localvoice-diarizer.exe") -Destination $OutputDirectory -Force

$notices = Join-Path $OutputDirectory 'licenses'
New-Item -ItemType Directory -Force $notices | Out-Null
Copy-Item -LiteralPath (Join-Path $SpeechSource 'LICENSE') -Destination (Join-Path $notices 'whisper.cpp-LICENSE.txt') -Force
Copy-Item -LiteralPath (Join-Path $EditorSource 'LICENSE') -Destination (Join-Path $notices 'llama.cpp-LICENSE.txt') -Force
foreach ($name in @('sherpa-onnx-LICENSE.txt', 'onnxruntime-LICENSE.txt', 'onnxruntime-ThirdPartyNotices.txt',
    'WeSpeaker-LICENSE.txt', 'Pyannote-segmentation-LICENSE.txt', 'Speaker-models-NOTICE.txt',
    'Qwen-LICENSE.txt', 'nlohmann-LICENSE.txt', 'Whisper-model-LICENSE.txt')) {
    Copy-Item -LiteralPath (Join-Path $ProjectRoot "Resources/$name") -Destination $notices -Force
}
Copy-Item -LiteralPath (Join-Path $ProjectRoot 'THIRD-PARTY-NOTICES.txt') -Destination $notices -Force
Copy-Item -LiteralPath (Join-Path $ProjectRoot 'LICENSE') -Destination (Join-Path $notices 'Voice-LICENSE.txt') -Force
Write-Host "Windows native engines built: $OutputDirectory"
