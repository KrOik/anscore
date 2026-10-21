param(
    [string]$OutputDir='',
    [string]$ReferenceSource='artifacts/ip_optimization_20260924/sha256/baseline_sha256_core.v'
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'env.ps1')
$root=$env:SIPEED_TANG20K_ROOT
if(!$OutputDir) {$OutputDir=Join-Path $root ('artifacts/sha_regression_'+(Get-Date -Format 'yyyyMMdd_HHmmss'))}
if(Test-Path $OutputDir) {throw "Choose a fresh output directory: $OutputDir"}
$out=(New-Item -ItemType Directory $OutputDir).FullName
$project=Join-Path $root 'cores/crypto/primitives'
$reference=(Resolve-Path $ReferenceSource).Path
$referenceText=Get-Content $reference -Raw
if(!$referenceText.Contains('module sha256_core (')) {throw 'Reference must define sha256_core'}
$referenceText.Replace('module sha256_core (','module sha256_reference (') | Set-Content (Join-Path $out 'sha256_reference.v')
New-Item -ItemType Directory (Join-Path $out 'sim') | Out-Null
Copy-Item (Join-Path $project 'sim/expected_report.mem') (Join-Path $out 'sim')
& python (Join-Path $project 'tools/gen_sha256_stress.py') --output-dir $out
if($LASTEXITCODE -ne 0) {throw 'Independent model generation failed'}
$sources=@(Get-ChildItem (Join-Path $project 'src/*.v') | ForEach-Object FullName)
$sources+=Join-Path $out 'sha256_reference.v'
$tests=@{
    tb_sha256_core='tb_sha256_core PASS'
    tb_sha256_stress='SHA_STRESS PASS'
    tb_sha256_rate_board='SHA_RATE_BOARD PASS'
    tb_crypto_selftest='tb_crypto_selftest PASS'
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
            throw "Simulation failed: $name; see $out/$name.log"
        }
        Write-Host "PASS $name"
    }
} finally {Pop-Location}
Write-Host "PASS SHA/crypto regression; evidence: $out"
