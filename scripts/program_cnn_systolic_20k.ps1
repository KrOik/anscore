$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'env.ps1')

$bitstream = Join-Path $env:SIPEED_TANG20K_ROOT 'cores\acceleration\cnn_systolic\build_oss\cnn_systolic_20k.fs'

if (!(Test-Path $bitstream)) {
    throw "Bitstream not found: $bitstream. Run scripts/build_cnn_systolic_20k_with_oss.ps1 first."
}

if (!(Get-Command openFPGALoader -ErrorAction SilentlyContinue)) {
    throw 'openFPGALoader not found. Run scripts/env.ps1 or install OSS CAD Suite/openFPGALoader.'
}

Write-Host "Programming Tang Primer 20K SRAM with $bitstream"
openFPGALoader -b tangprimer20k $bitstream
