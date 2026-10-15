param([Parameter(Mandatory=$true)][string]$OutputDir)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'env.ps1')
$project=Join-Path $env:SIPEED_TANG20K_ROOT 'cores/acceleration/cnn_systolic'
if(Test-Path $OutputDir) {throw 'Use a fresh output directory'}
& $env:OSS_CAD_PYTHON "$project/tools/gen_output_accumulation_vectors.py" --output $OutputDir
if($LASTEXITCODE -ne 0) {throw 'Fixture generation failed'}
$out=(Resolve-Path $OutputDir).Path
Copy-Item "$project/*.mem" $out
New-Item -ItemType Directory "$out/sim" | Out-Null
Copy-Item "$project/sim/expected_report*.mem" "$out/sim"
Copy-Item "$out/cnn_all_expected.mem" "$out/sim/expected_report.mem"
Push-Location $out
try {
 $configs=@(@(1,1,1,1),@(1,3,1,1),@(1,3,2,2),@(1,4,4,3),@(2,3,3,2),@(3,2,2,3),@(4,1,4,2),@(4,3,4,3),@(1,3,2,9),@(1,3,2,10),@(2,3,2,12),@(3,2,3,16),@(1,3,2,10,1024))
 foreach($cfg in $configs) {
  $name='acc_'+($cfg -join '_')
  $zeros=@(1..($cfg[0]*$cfg[2]) | ForEach-Object {'0000000000000000'})
  $zeros | Set-Content accumulation_bias.mem
  $params=@('-P',"tb_output_layer_accumulation.CPO=$($cfg[0])",'-P',"tb_output_layer_accumulation.CPI=$($cfg[1])",'-P',"tb_output_layer_accumulation.COLS=$($cfg[2])",'-P',"tb_output_layer_accumulation.PAGES=$($cfg[3])")
  if($cfg.Count -gt 4) {$params+=@('-P',"tb_output_layer_accumulation.SCALE=$($cfg[4])")}
  & iverilog -g2012 -s tb_output_layer_accumulation @params -o "$name.vvp" "$project/sim/tb_output_layer_accumulation.v" "$project/src/output_layer.v" 2> "$name.compile.log"
  if($LASTEXITCODE -ne 0) {throw "$name compile failed"}
  & vvp "$name.vvp" | Tee-Object "$name.log"
  if($LASTEXITCODE -ne 0 -or -not (Select-String "$name.log" -Pattern '^PASS output accumulation')) {throw "$name failed"}
 }
 $sources=@('pe','pe_col','pe_page','d_manager','w_manager','sdp_ram','my_fifo','max_pool2d','activation_lut','input_layer','output_layer','layer','extrema_finder','lprnet_spatial_sum','lprnet_post_process','cnn_selftest','uart_tx','top' | ForEach-Object {"$project/src/$_.v"})
 foreach($bench in @('tb_cnn_selftest','tb_top_uart_report')) {
  & iverilog -g2012 -s $bench -o "$bench.vvp" "$project/sim/$bench.v" @sources 2> "$bench.compile.log"
  if($LASTEXITCODE -ne 0) {throw "$bench compile failed"}
  & vvp "$bench.vvp" | Tee-Object "$bench.log"
  if($LASTEXITCODE -ne 0 -or (Select-String "$bench.log" -Pattern '\bFAIL\b|TIMEOUT|ERROR:') -or -not (Select-String "$bench.log" -Pattern 'PASS')) {throw "$bench failed"}
 }
 @('0000000000000000','0000000000000000') | Set-Content accumulation_bias.mem
 & iverilog -g2012 -s tb_output_layer_rate_board -o board.vvp "$project/sim/tb_output_layer_rate_board.v" "$project/src/output_layer_rate_board.v" "$project/src/output_layer.v" "$project/src/uart_tx.v" 2> board.compile.log
 if($LASTEXITCODE -ne 0) {throw 'Board bench compilation failed'}
 & vvp board.vvp | Tee-Object board.log
 if($LASTEXITCODE -ne 0 -or -not (Select-String board.log -Pattern '^PASS output-layer board')) {throw 'Board bench failed'}
} finally {Pop-Location}
