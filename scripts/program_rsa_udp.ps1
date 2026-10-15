$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'env.ps1')

$bitstream = Join-Path $env:SIPEED_TANG20K_ROOT 'cores\crypto\rsa_udp\build_oss\rsa_udp_20k.fs'
if (!(Test-Path $bitstream)) {
    throw "Bitstream not found: $bitstream. Run scripts/build_rsa_udp_with_oss.ps1 first."
}

Write-Host "Programming Tang Primer 20K SRAM with $bitstream"
openFPGALoader -b tangprimer20k $bitstream
