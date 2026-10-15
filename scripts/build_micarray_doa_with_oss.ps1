$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'env.ps1')

$project = Join-Path $env:SIPEED_TANG20K_ROOT 'cores\acquisition\micarray_doa'
$build = Join-Path $project 'build_oss'
New-Item -ItemType Directory -Force -Path $build | Out-Null

$sources = @(
    'src/micarray_doa_core.v',
    'src/mic_noise_filter.v',
    'src/led_direction_filter.v',
    'src/sk9822_driver.v',
    '..\micarry_audio_capture_20k\src\micarry_i2s_slots.v',
    'src/uart_tx.v',
    'src/doa_uart_reporter.v',
    'src/top.v'
) | ForEach-Object { (Join-Path $project $_).Replace('\', '/') }

$json = (Join-Path $build 'top.json').Replace('\', '/')
$pnr = (Join-Path $build 'pnr.json').Replace('\', '/')
$fs = Join-Path $build 'micarray_doa_20k.fs'
$cst = (Join-Path $project 'src/top.cst').Replace('\', '/')
$gowinPack = Join-Path $env:SIPEED_TANG20K_ROOT 'tools\oss-cad-suite\oss-cad-suite\bin\gowin_pack-script.py'
$ossPython = $env:OSS_CAD_PYTHON

if (!(Test-Path $ossPython)) {
    throw "OSS CAD Suite python not found: $ossPython"
}

if (!(Test-Path $gowinPack)) {
    throw "gowin_pack script not found: $gowinPack"
}

yosys -p "read_verilog $($sources -join ' '); synth_gowin -family gw2a -top top -json $json"
if ($LASTEXITCODE -ne 0) {
    throw "yosys failed with exit code $LASTEXITCODE"
}

nextpnr-himbaechel --json $json --write $pnr --device GW2A-LV18PG256C8/I7 --vopt family=GW2A-18 --vopt cst=$cst
if ($LASTEXITCODE -ne 0) {
    throw "nextpnr-himbaechel failed with exit code $LASTEXITCODE"
}

& $ossPython $gowinPack -d GW2A-18 -o $fs $pnr
if ($LASTEXITCODE -ne 0) {
    throw "gowin_pack failed with exit code $LASTEXITCODE"
}

Get-Item $fs | Select-Object FullName,Length
