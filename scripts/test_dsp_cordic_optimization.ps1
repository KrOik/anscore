param([string]$OutputDir='', [string]$ReferenceSource='')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'env.ps1')
$root=$env:SIPEED_TANG20K_ROOT
if(!$OutputDir) {$OutputDir=Join-Path $root ('artifacts/cordic_regression_'+(Get-Date -Format 'yyyyMMdd_HHmmss'))}
if(Test-Path $OutputDir) {throw "Choose a fresh output directory: $OutputDir"}
$out=(New-Item -ItemType Directory $OutputDir).FullName
$project=Join-Path $root 'cores/signal_processing/dsp'
if($ReferenceSource) {$reference=(Resolve-Path $ReferenceSource).Path.Replace('\','/')}
New-Item -ItemType Directory (Join-Path $out 'sim') | Out-Null
Copy-Item (Join-Path $project 'sim/expected_report.mem') (Join-Path $out 'sim')
Copy-Item (Join-Path $project 'sine256.mem') $out
& python (Join-Path $project 'tools/gen_cordic_stress.py') --output (Join-Path $out 'cordic_vectors.mem') --board-output (Join-Path $out 'cordic_board_expected.mem')
if($LASTEXITCODE -ne 0) {throw 'Independent model generation failed'}
$sources=@(Get-ChildItem (Join-Path $project 'src/*.v') | ForEach-Object FullName)
$tests=@{
    tb_cordic_stress='CORDIC_STRESS PASS'
    tb_cordic_rate_board='CORDIC_RATE_BOARD PASS'
    tb_dsp_selftest='tb_dsp_selftest PASS'
    tb_top_uart_report='tb_top_uart_report PASS'
}
Push-Location $out
try {
    foreach($name in ($tests.Keys | Sort-Object)) {
        & iverilog -g2012 -s $name -o "$name.vvp" @sources (Join-Path $project "sim/$name.v")
        if($LASTEXITCODE -ne 0) {throw "Compile failed: $name"}
        $lines=@(& vvp "$name.vvp" 2>&1); $code=$LASTEXITCODE
        $lines | Set-Content "$name.log"
        $text=$lines -join "`n"
        if($code -ne 0 -or $text -notmatch [regex]::Escape($tests[$name]) -or $text -match '\bFAIL\b|\bFATAL\b|\btimeout\b') {
            throw "Simulation failed: $name (see $out/$name.log)"
        }
        Write-Host "PASS $name"
    }
    if($ReferenceSource) {
        $current=(Join-Path $project 'src/cordic.v').Replace('\','/')
        @"
read_verilog -sv "$reference"
rename cordic reference
read_verilog -sv "$current"
rename cordic optimized
proc
memory_map
opt
async2sync
opt
equiv_make reference optimized equiv
hierarchy -top equiv
equiv_simple -seq 1
equiv_induct -seq 2
equiv_status -assert
"@ | Set-Content equivalence.ys
        & yosys -Q -l equivalence.log equivalence.ys > equivalence_console.log
        if($LASTEXITCODE -ne 0) {throw 'RTL equivalence failed'}
        Write-Host 'PASS RTL equivalence under async2sync reset model'
    }
} finally {Pop-Location}
Write-Host "PASS CORDIC/DSP regression; evidence: $out"
