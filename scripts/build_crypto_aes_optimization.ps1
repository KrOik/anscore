param(
    [Parameter(Mandatory=$true)][string]$OutputDir,
    [string]$CoreSource = 'cores/crypto/primitives/src/aes128_core.v',
    [switch]$FullRate
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'env.ps1')
$root = $env:SIPEED_TANG20K_ROOT
if (Test-Path $OutputDir) { throw "Choose a fresh output directory: $OutputDir" }
$out = (New-Item -ItemType Directory $OutputDir).FullName.Replace('\','/')
$aes = (Resolve-Path $CoreSource).Path.Replace('\','/')
$project = (Join-Path $root 'cores/crypto/primitives').Replace('\','/')
$sources = @($aes, "$project/src/sha256_core.v", "$project/src/crc_core.v",
    "$project/src/crypto_selftest.v", "$project/src/uart_tx.v", "$project/src/la_debug_top.v")
$top = 'la_debug_top'
$config = 'chparam -set UNIT_EN 1 la_debug_top'
if ($FullRate) {
    $sources = @($aes, "$project/src/uart_tx.v", "$project/src/aes128_rate_board.v")
    $top = 'aes128_rate_board'
    $config = ''
}
$sourceArgs = ($sources | ForEach-Object { '"' + $_ + '"' }) -join ' '
$ys = "read_verilog -sv $sourceArgs`n$config`nsynth_gowin -noalu -family gw2a -top $top -json `"$out/top.json`"`nstat"
$ys | Set-Content "$out/build.ys"
$sources | ForEach-Object { Get-FileHash -Algorithm SHA256 -LiteralPath $_ } | ConvertTo-Json | Set-Content "$out/source_hashes.json"
& yosys -Q -l "$out/yosys.log" "$out/build.ys" > "$out/synth_console.log"
if ($LASTEXITCODE -ne 0) { throw 'Synthesis failed' }
$netlist = Get-Content "$out/top.json" -Raw | ConvertFrom-Json -AsHashtable
$types = @($netlist.modules[$top].cells.Values | ForEach-Object { $_.type })
$lut = @($types | Where-Object {$_ -match '^LUT[1-4]$|^ALU$'}).Count
$dsp = @($types | Where-Object {$_ -match '^(MULT|PADD|ALU54)'}).Count
if ($lut -gt 15000 -or $dsp -gt 4) { throw "Resource budget failed: LUT=$lut DSP=$dsp" }
& nextpnr-himbaechel --json "$out/top.json" --write "$out/pnr.json" --device GW2A-LV18PG256C8/I7 --vopt family=GW2A-18 --vopt "cst=$project/src/la_debug.cst" --freq 27 --seed 1 --log "$out/nextpnr.log" > "$out/pnr_console.log" 2>&1
if ($LASTEXITCODE -ne 0) { throw 'Place/route or timing failed' }
& $env:OSS_CAD_PYTHON (Join-Path $root 'tools/oss-cad-suite/oss-cad-suite/bin/gowin_pack-script.py') -d GW2A-18 -o "$out/aes.fs" "$out/pnr.json" > "$out/pack.log" 2>&1
if ($LASTEXITCODE -ne 0) { throw 'Bitstream pack failed' }
Write-Host "PASS AES-only board build LUT1-4=$lut DSP=$dsp at $out"
