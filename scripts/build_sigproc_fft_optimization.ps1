param(
 [Parameter(Mandatory=$true)][string]$OutputDir,
 [string]$CoreSource='cores/signal_processing/transforms/src/fft64.v',
 [switch]$DiagnosticInput,
 [switch]$NoWideLut,
 [ValidateSet(1,16)][int]$EnableDiv=1,
 [switch]$Legacy
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'env.ps1')
$root=$env:SIPEED_TANG20K_ROOT
$project=(Join-Path $root 'cores/signal_processing/transforms').Replace('\','/')
$core=(Resolve-Path $CoreSource).Path.Replace('\','/')
& $env:OSS_CAD_PYTHON "$project/tools/gen_fft_stress_vectors.py" --output $OutputDir
if($LASTEXITCODE -ne 0) {throw 'Fixture generation failed; use a fresh output directory'}
$out=(Resolve-Path $OutputDir).Path.Replace('\','/')
$sources=@($core,"$project/src/fft64_rate_board.v","$project/src/sig_sdp_ram.v",
 "$project/src/tw_rom_cos.v","$project/src/tw_rom_sin.v","$project/src/uart_tx.v")
$top='fft64_rate_board'; $cst="$project/src/fft_stream.cst"
if($Legacy) {
 if($DiagnosticInput -or $EnableDiv -ne 1) {throw 'Legacy build cannot use diagnostic flags'}
 $top='la_debug_top'; $cst="$project/src/la_debug.cst"
 $sources=@($core)+@('sig_sdp_ram','tw_rom_cos','tw_rom_sin','cic_dec8','hist256','otsu_thresh','sig_selftest','uart_tx','top','la_debug_top' | ForEach-Object {"$project/src/$_.v"})
 Copy-Item "$project/*.mem" $out
}
New-Item -ItemType Directory "$out/sources" | Out-Null
$snapshots=@($sources | ForEach-Object {
 $target=Join-Path "$out/sources" (Split-Path $_ -Leaf)
 Copy-Item -LiteralPath $_ -Destination $target
 $target.Replace('\','/')
})
$sourceArgs=($snapshots | ForEach-Object {'"'+$_+'"'}) -join ' '
$diag=[int][bool]$DiagnosticInput
$config="chparam -set DIAGNOSTIC_INPUT $diag -set ENABLE_DIV $EnableDiv fft64_rate_board"
if($Legacy) {$config=''}
$mapping=''
if($NoWideLut) {$mapping='-nowidelut'}
"read_verilog -sv $sourceArgs`n$config`nsynth_gowin -noalu $mapping -family gw2a -top $top -json top.json`nstat" | Set-Content "$out/build.ys"
@($sources+@($cst)+@(Get-ChildItem "$out/*.mem" | ForEach-Object {$_.FullName})) | ForEach-Object {Get-FileHash -Algorithm SHA256 -LiteralPath $_} | ConvertTo-Json | Set-Content "$out/source_hashes.json"
Push-Location $out
try {
 & yosys -Q -l yosys.log build.ys > synth_console.log
 if($LASTEXITCODE -ne 0) {throw 'Synthesis failed'}
 $net=Get-Content top.json -Raw | ConvertFrom-Json -AsHashtable
 $types=@($net.modules[$top].cells.Values | ForEach-Object {$_.type})
 $lut=@($types | Where-Object {$_ -match '^LUT[1-4]$|^ALU$'}).Count
 $dsp=@($types | Where-Object {$_ -match '^(MULT|PADD|ALU54)'}).Count
 if($lut -gt 15000 -or $dsp -gt 4) {throw "Budget failed LUT=$lut DSP=$dsp"}
 & nextpnr-himbaechel --json top.json --write pnr.json --device GW2A-LV18PG256C8/I7 --vopt family=GW2A-18 --vopt "cst=$cst" --freq 27 --seed 1 --log nextpnr.log > pnr_console.log 2>&1
 if($LASTEXITCODE -ne 0) {throw 'Place/route or timing failed'}
 & $env:OSS_CAD_PYTHON "$root/tools/oss-cad-suite/oss-cad-suite/bin/gowin_pack-script.py" -d GW2A-18 -o fft64.fs pnr.json > pack.log 2>&1
 if($LASTEXITCODE -ne 0) {throw 'Pack failed'}
 Write-Host "PASS $top board build LUT1-4=$lut DSP=$dsp at $out"
} finally {Pop-Location}
