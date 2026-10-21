param(
 [Parameter(Mandatory=$true)][string]$OutputDir,
 [string]$InputSource='cores/acceleration/cnn_systolic/src/input_layer.v',
 [string]$LayerSource='cores/acceleration/cnn_systolic/src/layer.v'
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/env.ps1"
if(Test-Path -LiteralPath $OutputDir){throw 'Use a fresh output directory.'}
$inputCore=(Resolve-Path -LiteralPath $InputSource).Path
$layerCore=(Resolve-Path -LiteralPath $LayerSource).Path
$project=Join-Path (Split-Path $PSScriptRoot -Parent) 'cores/acceleration/cnn_systolic'
New-Item -ItemType Directory $OutputDir | Out-Null
$out=(Resolve-Path $OutputDir).Path
Copy-Item "$project/weight_layer9_page0.mem","$project/weight_layer9_page1.mem","$project/bias_layer9.mem" $out
Get-FileHash $inputCore,$layerCore,"$project/sim/tb_input_layer_stream.v" | ConvertTo-Json | Set-Content "$out/source_hashes.json"
$sources=@('pe','pe_col','pe_page','d_manager','w_manager','output_layer','sdp_ram','max_pool2d' | ForEach-Object {"$project/src/$_.v"})
$results=@()
Push-Location $out
try {
 # GAP, STALL, RANDOM_GAPS, RESET_MID, width, height, ROW_IDLE
 foreach($cfg in @(@(0,0,0,0,8,6,32),@(2,0,0,0,8,6,32),@(5,1,0,0,8,6,32),@(0,0,0,0,8,6,6),@(0,1,1,0,8,6,32),@(0,1,1,1,8,6,32),@(0,1,1,1,5,4,32),@(0,1,1,1,9,7,32),@(0,1,1,1,16,6,32),@(0,1,1,1,31,6,64),@(0,0,0,0,128,6,256),@(0,1,1,1,128,6,256))) {
  $name='case_'+($cfg -join '_')
  $params=@('-P','tb_input_layer_stream.CHECK_LAYER=1')
  $keys=@('GAP','STALL','RANDOM_GAPS','RESET_MID','IMG_W','IMG_H','ROW_IDLE')
  for($i=0;$i -lt $keys.Count;$i++){ $params+=@('-P',"tb_input_layer_stream.$($keys[$i])=$($cfg[$i])") }
  & iverilog -g2012 -s tb_input_layer_stream @params -o "$name.vvp" "$project/sim/tb_input_layer_stream.v" $inputCore $layerCore @sources 2> "$name.compile.log"
  if($LASTEXITCODE -ne 0){throw "Compile failed $name"}
  & vvp "$name.vvp" | Tee-Object "$name.log"
  $code=$LASTEXITCODE
  $results+=@{case=$name;exit_code=$code;pass=($code -eq 0)}
 }
 $results | ConvertTo-Json | Set-Content results.json
 if(@($results | Where-Object {-not $_.pass}).Count){throw 'Integration failures; see results.json.'}
} finally {Pop-Location}
