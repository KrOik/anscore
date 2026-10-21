param([Parameter(Mandatory=$true)][string]$OutputDir)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../../../../scripts/env.ps1"
if(Test-Path -LiteralPath $OutputDir){throw 'Use a fresh output directory'}
$out=(New-Item -ItemType Directory $OutputDir).FullName
foreach($k in @(3,5)) {
 $case=New-Item -ItemType Directory (Join-Path $out "k$k")
 Copy-Item "$PSScriptRoot/stream_window.v" "$case/stream_window.v"
 Get-FileHash "$case/stream_window.v" | ConvertTo-Json | Set-Content "$case/source_hash.json"
 @"
read_verilog -sv stream_window.v
chparam -set WIDTH 32 -set HEIGHT 24 -set DATA_WIDTH 10 -set K $k stream_window
synth_gowin -noalu -family gw2a -top stream_window -json core.json
stat
"@ | Set-Content "$case/build.ys"
 Push-Location $case
 try {
  & yosys -Q -l synth.log build.ys > console.log 2>&1
  if($LASTEXITCODE -ne 0){throw "K=$k synthesis failed"}
  $net=Get-Content core.json -Raw | ConvertFrom-Json -AsHashtable
  $types=@($net.modules.stream_window.cells.Values | ForEach-Object {$_.type})
  $counts=[ordered]@{stage='isolated synthesis';K=$k;WIDTH=32;HEIGHT=24;DATA_WIDTH=10;
   LUT=@($types | Where-Object {$_ -match '^LUT[1-4]$'}).Count;
   FF=@($types | Where-Object {$_ -match '^DFF'}).Count;
   DSP=@($types | Where-Object {$_ -match '^(MULT|PADD|ALU54)'}).Count;
   BRAM=@($types | Where-Object {$_ -match '^(SP|SDP|DP)(X9|X9B|B)?$'}).Count}
  $counts | ConvertTo-Json | Set-Content resources.json
  if($counts.LUT -gt 15000 -or $counts.DSP -gt 4){throw 'Core resource gate failed'}
  Write-Host ($counts | ConvertTo-Json -Compress)
 } finally {Pop-Location}
}
