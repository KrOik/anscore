param([Parameter(Mandatory=$true)][string]$OutputDir)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/env.ps1"
if(Test-Path $OutputDir){throw 'Use a fresh output directory.'}
New-Item -ItemType Directory $OutputDir | Out-Null
$project=Join-Path (Split-Path $PSScriptRoot -Parent) 'cores/acceleration/cnn_systolic'
foreach($cfg in @(@(1,1),@(1,8),@(2,8),@(4,8),@(9,1),@(9,7),@(9,16),@(16,8),@(25,8),@(25,16))) {
 $stem=Join-Path $OutputDir "lanes$($cfg[0])_width$($cfg[1])"
 & iverilog -g2012 -s tb_max_pool2d_stream -P "tb_max_pool2d_stream.LANES=$($cfg[0])" -P "tb_max_pool2d_stream.WIDTH=$($cfg[1])" -o "$stem.vvp" "$project/sim/tb_max_pool2d_stream.v" "$project/src/max_pool2d.v" 2> "$stem.compile.log"
 if($LASTEXITCODE -ne 0){throw "Compile failed $stem"}
 & vvp "$stem.vvp" | Tee-Object "$stem.log"
 if($LASTEXITCODE -ne 0){throw "Simulation failed $stem"}
}
