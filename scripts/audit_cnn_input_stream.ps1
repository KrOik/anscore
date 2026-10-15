param([Parameter(Mandatory=$true)][string]$OutputDir, [string]$CoreSource)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/env.ps1"
if(Test-Path -LiteralPath $OutputDir) { throw 'Use a fresh output directory.' }
New-Item -ItemType Directory -Path $OutputDir | Out-Null
$root=Split-Path $PSScriptRoot -Parent
if(-not $CoreSource) {$CoreSource="$root/cores/acceleration/cnn_systolic/src/input_layer.v"}
$CoreSource=(Resolve-Path -LiteralPath $CoreSource).Path
$results=@()
foreach($cfg in @(@(0,0,32),@(0,1,32),@(1,0,32),@(2,0,32),@(5,1,32),@(0,0,6))) {
 $stem=Join-Path $OutputDir "gap$($cfg[0])_stall$($cfg[1])_idle$($cfg[2])"
 & iverilog -g2012 -s tb_input_layer_stream -P "tb_input_layer_stream.GAP=$($cfg[0])" -P "tb_input_layer_stream.STALL=$($cfg[1])" -P "tb_input_layer_stream.ROW_IDLE=$($cfg[2])" -o "$stem.vvp" "$root/cores/acceleration/cnn_systolic/sim/tb_input_layer_stream.v" $CoreSource "$root/cores/acceleration/cnn_systolic/src/sdp_ram.v" 2> "$stem.compile.log"
 if($LASTEXITCODE -ne 0) {throw "Compile failed: $stem"}
 & vvp "$stem.vvp" | Tee-Object "$stem.log"
 $code=$LASTEXITCODE
 $results+=@{gap=$cfg[0];stall=$cfg[1];row_idle=$cfg[2];exit_code=$code;pass=($code -eq 0)}
}
$results | ConvertTo-Json | Set-Content (Join-Path $OutputDir 'results.json')
if(@($results | Where-Object {-not $_.pass}).Count) {throw 'Input stream audit found failing cases; see results.json. This is not a passing regression.'}
