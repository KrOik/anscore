param([Parameter(Mandatory=$true)][string]$OutputDir,
 [string]$CoreSource='cores/acceleration/cnn_systolic/src/lprnet_spatial_sum.v',
 [switch]$Legacy)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/env.ps1"
$root=$env:SIPEED_TANG20K_ROOT
$project=(Join-Path $root 'cores/acceleration/cnn_systolic').Replace('\','/')
$core=(Resolve-Path $CoreSource).Path.Replace('\','/')
& python "$project/tools/spatial_sum_board_model.py" --generate $OutputDir
if($LASTEXITCODE -ne 0){throw 'Fixture generation failed; use a fresh directory'}
$out=(Resolve-Path $OutputDir).Path.Replace('\','/')
$top='spatial_sum_rate_board'
$sources=@($core,"$project/src/spatial_sum_rate_board.v","$project/src/sdp_ram.v","$project/src/uart_tx.v")
if($Legacy){
 $top='cnn_spatial_legacy_board'
 $sources=@($core)+@('pe','pe_col','pe_page','d_manager','w_manager','sdp_ram','my_fifo','max_pool2d','activation_lut','input_layer','output_layer','layer','extrema_finder','lprnet_post_process','cnn_selftest','uart_tx','top','cnn_spatial_legacy_board' | ForEach-Object {"$project/src/$_.v"})
 Copy-Item "$project/*.mem" $out
}
New-Item -ItemType Directory "$out/sources" | Out-Null
$snapshots=@($sources | ForEach-Object {
 $target=Join-Path "$out/sources" (Split-Path $_ -Leaf)
 Copy-Item -LiteralPath $_ -Destination $target
 $target.Replace('\','/')
})
$argsText=($snapshots | ForEach-Object {'"'+$_+'"'}) -join ' '
"read_verilog -sv $argsText`nsynth_gowin -noalu -family gw2a -top $top -json top.json`nstat" | Set-Content "$out/build.ys"
@($sources+@("$project/src/output_layer_rate.cst")+@(Get-ChildItem "$out/*.mem" | ForEach-Object {$_.FullName})) | ForEach-Object {Get-FileHash -Algorithm SHA256 -LiteralPath $_} | ConvertTo-Json | Set-Content "$out/source_hashes.json"
Push-Location $out
try {
 & yosys -Q -l yosys.log build.ys > synth_console.log
 if($LASTEXITCODE -ne 0){throw 'Synthesis failed'}
 $net=Get-Content top.json -Raw | ConvertFrom-Json -AsHashtable
 $entries=@($net.modules.GetEnumerator() | Where-Object {([string]$_.Value.attributes.top) -match '^0*1$'})
 if($entries.Count -ne 1 -or $entries[0].Value.cells.Count -eq 0){throw 'Invalid synthesized top'}
 $types=@($entries[0].Value.cells.Values | ForEach-Object {$_.type})
 $lut=@($types | Where-Object {$_ -match '^LUT[1-4]$|^ALU$'}).Count
 $dsp=@($types | Where-Object {$_ -match '^(MULT|PADD|ALU54)'}).Count
 if($lut -gt 15000 -or $dsp -gt 4){throw "Budget failed LUT=$lut DSP=$dsp"}
 & nextpnr-himbaechel --json top.json --write pnr.json --device GW2A-LV18PG256C8/I7 --vopt family=GW2A-18 --vopt "cst=$project/src/output_layer_rate.cst" --freq 27 --seed 1 --log nextpnr.log > pnr_console.log 2>&1
 if($LASTEXITCODE -ne 0){throw 'Place/route or timing failed'}
 $match=[regex]::Match((Get-Content nextpnr.log -Raw),'\bLUT4:\s+(\d+)')
 if(-not $match.Success -or [int]$match.Groups[1].Value -gt 15000){throw 'Routed LUT gate failed'}
 & $env:OSS_CAD_PYTHON "$root/tools/oss-cad-suite/oss-cad-suite/bin/gowin_pack-script.py" -d GW2A-18 -o spatial_sum.fs pnr.json > pack.log 2>&1
 if($LASTEXITCODE -ne 0){throw 'Pack failed'}
 Write-Host "PASS $top synthesized LUT=$lut routed LUT4=$($match.Groups[1].Value) DSP=$dsp"
} finally {Pop-Location}
