$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'env.ps1')

$bitstream = Join-Path $env:SIPEED_TANG20K_ROOT 'cores\storage\sdcard_spi\build_oss\sdcard_spi_20k.fs'
if (!(Test-Path $bitstream)) {
    throw "Bitstream not found: $bitstream. Run scripts/build_sdcard_spi_with_oss.ps1 first."
}

$loader = Join-Path $env:SIPEED_TANG20K_ROOT 'tools\openFPGALoader\ucrt64\bin\openFPGALoader.exe'
if (!(Test-Path $loader)) { $loader = 'openFPGALoader' }

Write-Host "Programming Tang Primer 20K SRAM with $bitstream"
$out = & $loader -b tangprimer20k $bitstream 2>&1 | ForEach-Object { $_.ToString() }
$out | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) { throw "openFPGALoader exit code $LASTEXITCODE" }
if ($out -match 'FAIL') { throw "openFPGALoader reported FAIL" }
Write-Host "SRAM programming DONE"
