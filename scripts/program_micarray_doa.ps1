$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'env.ps1')

$project = Join-Path $env:SIPEED_TANG20K_ROOT 'cores\acquisition\micarray_doa'
$candidates = @(
    (Join-Path $project 'build_oss\micarray_doa_20k.fs'),
    (Join-Path $project 'impl\pnr\micarray_doa_20k.fs'),
    (Join-Path $project 'impl\pnr\project.fs'),
    (Join-Path $project 'micarray_doa_20k.fs')
)

$bitstream = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (!$bitstream) {
    throw 'No generated .fs bitstream found. Run scripts/build_micarray_doa_with_gowin.ps1 after fixing pins.'
}

openFPGALoader -b tangprimer20k $bitstream
