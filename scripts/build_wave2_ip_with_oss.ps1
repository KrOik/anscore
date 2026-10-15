$ErrorActionPreference = 'Stop'
# ============================================================================
# build_wave2_ip_with_oss.ps1 -- OSS CAD build for wave2_ip_20k top.
#   -Mask <40-bit hex>   UNIT_EN mask (default FFFFFFFFFF = all 40 units)
#   -SynthOnly           skip nextpnr/pack (resource probe)
# NOTE: full-mask synth can hit yosys bad_alloc on this host; use half masks
# (00000FFFFF / FFFFF00000) for board bitstreams.
# ============================================================================
#   -NoAlu               synth_gowin -noalu (REQUIRED for board bitstreams:
#                        GW2A ALU carry cells misbehave on silicon -- CSC Cr
#                        path produced small deterministic errors; LUT-only
#                        build verified correct, digest CE41D92D)
param(
    [string]$Mask = 'FFFFFFFFFF',
    [switch]$SynthOnly,
    [switch]$NoAlu
)

. (Join-Path $PSScriptRoot 'env.ps1')

$project = Join-Path $env:SIPEED_TANG20K_ROOT 'cores\system\extended_library'
$src = Join-Path $project 'src'
$imgwin = Join-Path $env:SIPEED_TANG20K_ROOT 'cores\image_processing\window\src'
$build = Join-Path $project 'build_oss'
New-Item -ItemType Directory -Force -Path $build | Out-Null

$allSrc = Get-ChildItem $src -Filter '*.v' | ForEach-Object { $_.FullName }
$allSrc += @(
    (Join-Path $imgwin 'win3x3_gen.v'),
    (Join-Path $imgwin 'line_buf_ram.v'),
    (Join-Path $imgwin 'median3x3.v'),
    (Join-Path $imgwin 'morph3x3.v'),
    (Join-Path $imgwin 'sobel_edge.v'),
    (Join-Path $imgwin 'threshold_bin.v'),
    (Join-Path $imgwin 'gaussian3x3.v'),
    (Join-Path $imgwin 'uart_tx.v')
)

$tag = "m$Mask"
if ($NoAlu) { $tag += "_noalu" }
$json = Join-Path $build ("top_{0}.json" -f $tag)
$pnr  = Join-Path $build ("pnr_{0}.json" -f $tag)
$fs   = Join-Path $build ("wave2_{0}.fs" -f $tag)

# one read_verilog command per file (yosys does not glob, and a single long
# command line hit arg parsing issues)
$readArgs = ($allSrc | ForEach-Object { "read_verilog -sv -I `"$src`" `"$_`";" }) -join ' '
$aluOpt = ''
if ($NoAlu) { $aluOpt = ' -noalu' }
$ys = "$readArgs chparam -set UNIT_EN 40'h$Mask top; synth_gowin -top top$aluOpt -json `"$json`"; stat"
Write-Host "== yosys synth (UNIT_EN=$Mask) =="
& yosys -p $ys | Tee-Object (Join-Path $build ("yosys_{0}.log" -f $tag))
if ($LASTEXITCODE -ne 0) { throw "yosys failed" }
if ($SynthOnly) { return }

Write-Host "== nextpnr =="
& nextpnr-himbaechel --json $json --write $pnr `
    --device GW2A-LV18PG256C8/I7 --vopt family=GW2A-18 `
    --vopt cst=(Join-Path $src 'top.cst') | Tee-Object (Join-Path $build ("nextpnr_{0}.log" -f $tag))
if ($LASTEXITCODE -ne 0) { throw "nextpnr failed" }

Write-Host "== gowin_pack =="
$pack = Join-Path $env:SIPEED_TANG20K_ROOT 'tools\gowin_pack-script.py'
if (!(Test-Path $pack)) { $pack = 'gowin_pack-script.py' }
& python $pack -d GW2A-18 -o $fs $pnr
if ($LASTEXITCODE -ne 0) { throw "gowin_pack failed" }
Write-Host "bitstream: $fs"
