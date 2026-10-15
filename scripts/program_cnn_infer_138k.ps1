param([switch]$Flash)
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'env.ps1')

$bitstream = Join-Path $env:SIPEED_TANG20K_ROOT 'cores\acceleration\cnn_inference\build_oss\cnn_infer_138k.fs'

if (!(Test-Path $bitstream)) {
    throw "Bitstream not found: $bitstream. Run scripts/build_cnn_infer_138k.ps1 first."
}

if (!(Get-Command openFPGALoader -ErrorAction SilentlyContinue)) {
    throw 'openFPGALoader not found. Run scripts/env.ps1 or install OSS CAD Suite/openFPGALoader.'
}

$oflArgs = @('-c', 'cmsisdap')
if ($Flash) { $oflArgs += '--flash' }
$oflArgs += $bitstream

Write-Host "Programming Tang Mega 138K Pro SOM (cmsisdap$(if ($Flash) {', flash'} else {', SRAM'})) with $bitstream"
openFPGALoader @oflArgs
if ($LASTEXITCODE -ne 0) {
    throw "openFPGALoader failed with exit code $LASTEXITCODE"
}
