param([Parameter(Mandatory=$true)][string]$OutputDir,
 [string]$CoreSource='cores/acceleration/cnn_systolic/src/lprnet_spatial_sum.v')
$ErrorActionPreference='Stop'
. "$PSScriptRoot/env.ps1"
if(Test-Path $OutputDir){throw 'Use a fresh output directory.'}
New-Item -ItemType Directory $OutputDir | Out-Null
$project=Join-Path (Split-Path $PSScriptRoot -Parent) 'cores/acceleration/cnn_systolic'
$core=(Resolve-Path $CoreSource).Path
$results=@()
foreach($depth in 1,2,3,4,8,16) {
 foreach($gaps in 0,1) {
 foreach($cfg in @(@(3,2,8,16),@(1,1,1,4),@(2,3,8,8),@(5,2,13,10))) {
  $rows,$lanes,$width,$acc=$cfg
  $stem=Join-Path $OutputDir "depth${depth}_gaps${gaps}_r${rows}_l${lanes}_w${width}_a${acc}"
  & iverilog -g2012 -s tb_spatial_sum_stream -P "tb_spatial_sum_stream.COLS=$depth" -P tb_spatial_sum_stream.CPO=1 -P "tb_spatial_sum_stream.GAPS=$gaps" -P "tb_spatial_sum_stream.ROWS=$rows" -P "tb_spatial_sum_stream.LANES=$lanes" -P "tb_spatial_sum_stream.WIDTH=$width" -P "tb_spatial_sum_stream.ACC=$acc" -o "$stem.vvp" "$project/sim/tb_spatial_sum_stream.v" $core "$project/src/sdp_ram.v" 2> "$stem.compile.log"
  if($LASTEXITCODE -ne 0){throw "Compile failed $stem"}
  & vvp "$stem.vvp" | Tee-Object "$stem.log"
  $code=$LASTEXITCODE
  $results+= [pscustomobject]@{depth=$depth;gaps=$gaps;rows=$rows;lanes=$lanes;width=$width;acc=$acc;exit_code=$code;pass=($code -eq 0)}
 }
 }
}
$results | ConvertTo-Json | Set-Content (Join-Path $OutputDir 'results.json')
if(@($results | Where-Object { -not $_.pass }).Count) {
 throw 'Spatial sum audit found functional failures; see results.json. Failures are not waived.'
}
