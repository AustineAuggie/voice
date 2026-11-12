param([Parameter(Mandatory = $true)][Alias('EngineDirectory')][string]$EnginesDirectory)
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
& python (Join-Path $projectRoot 'Windows/tests/native_smoke.py') --engines $EnginesDirectory --no-inference
if ($LASTEXITCODE -ne 0) { throw 'Windows native engine smoke checks failed.' }
