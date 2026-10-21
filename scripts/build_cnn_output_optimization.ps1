param(
 [Parameter(Mandatory=$true)][string]$OutputDir,
 [string]$CoreSource='cores/acceleration/cnn_systolic/src/output_layer.v',
 [switch]$Legacy,
 [ValidateRange(1,16)][int]$Pages=2
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'env.ps1')
$root=$env:SIPEED_TANG20K_ROOT
$project=(Join-Path $root 'cores/acceleration/cnn_systolic').Replace('\','/')
$core=(Resolve-Path $CoreSource).Path.Replace('\','/')
& $env:OSS_CAD_PYTHON "$project/tools/gen_output_accumulation_vectors.py" --output $OutputDir --pages $Pages
if($LASTEXITCODE -ne 0) {throw 'Fixture generation failed; use a fresh directory'}
$out=(Resolve-Path $OutputDir).Path.Replace('\','/')
Copy-Item "$project/*.mem" $out
$top='output_layer_rate_board'
$sources=@($core,"$project/src/output_layer_rate_board.v","$project/src/uart_tx.v")
if($Legacy) {
 $top='cnn_output_legacy_board'
 $sources=@($core)+@('pe','pe_col','pe_page','d_manager','w_manager','sdp_ram','my_fifo','max_pool2d','activation_lut','input_layer','layer','extrema_finder','lprnet_spatial_sum','lprnet_post_process','cnn_selftest','uart_tx','top','cnn_output_legacy_board' | ForEach-Object {"$project/src/$_.v"})
}
New-Item -ItemType Directory "$out/sources" | Out-Null
$snapshots=@($sources | ForEach-Object {
 $target=Join-Path "$out/sources" (Split-Path $_ -Leaf)
 Copy-Item -LiteralPath $_ -Destination $target
 $target.Replace('\','/')
})
$sourceArgs=($snapshots | ForEach-Object {'"'+$_+'"'}) -join ' '
$config="chparam -set PAGES $Pages output_layer_rate_board"
if($Legacy) {$config=''}
"read_verilog -sv $sourceArgs`n$config`nsynth_gowin -noalu -family gw2a -top $top -json top.json`nstat" | Set-Content "$out/build.ys"
@($sources+@("$project/src/output_layer_rate.cst")+@(Get-ChildItem "$out/*.mem" | ForEach-Object {$_.FullName})) | ForEach-Object {Get-FileHash -Algorithm SHA256 -LiteralPath $_} | ConvertTo-Json | Set-Content "$out/source_hashes.json"
Push-Location $out
try {
 & yosys -Q -l yosys.log build.ys > synth_console.log
 if($LASTEXITCODE -ne 0) {throw 'Synthesis failed'}
 $net=Get-Content top.json -Raw | ConvertFrom-Json -AsHashtable
 # Parameter specialization may rename the top; never count a missing name as zero.
 $topEntries=@($net.modules.GetEnumerator() | Where-Object {([string]$_.Value.attributes.top) -match '^0*1$'})
 if($topEntries.Count -ne 1 -or $topEntries[0].Value.cells.Count -eq 0) {throw 'Missing or ambiguous synthesized top'}
 $types=@($topEntries[0].Value.cells.Values | ForEach-Object {$_.type})
 $lut=@($types | Where-Object {$_ -match '^LUT[1-4]$|^ALU$'}).Count
 $dsp=@($types | Where-Object {$_ -match '^(MULT|PADD|ALU54)'}).Count
 if($lut -gt 15000 -or $dsp -gt 4) {throw "Budget failed LUT=$lut DSP=$dsp"}
 & nextpnr-himbaechel --json top.json --write pnr.json --device GW2A-LV18PG256C8/I7 --vopt family=GW2A-18 --vopt "cst=$project/src/output_layer_rate.cst" --freq 27 --seed 1 --log nextpnr.log > pnr_console.log 2>&1
 if($LASTEXITCODE -ne 0) {throw 'Place/route or timing failed'}
 $routedMatch=[regex]::Match((Get-Content nextpnr.log -Raw),'\bLUT4:\s+(\d+)')
 if(-not $routedMatch.Success -or [int]$routedMatch.Groups[1].Value -gt 15000) {throw 'Routed LUT4 budget check failed'}
 & $env:OSS_CAD_PYTHON "$root/tools/oss-cad-suite/oss-cad-suite/bin/gowin_pack-script.py" -d GW2A-18 -o cnn_output.fs pnr.json > pack.log 2>&1
 if($LASTEXITCODE -ne 0) {throw 'Pack failed'}
 Write-Host "PASS $top build synthesized LUT1-4=$lut routed LUT4=$($routedMatch.Groups[1].Value) DSP=$dsp at $out"
} finally {Pop-Location}
