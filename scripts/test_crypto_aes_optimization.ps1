param([string]$OutputDir = '')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'env.ps1')
$root = $env:SIPEED_TANG20K_ROOT
if (!$OutputDir) { $OutputDir = Join-Path $root ('artifacts/aes_regression_' + (Get-Date -Format 'yyyyMMdd_HHmmss')) }
if (Test-Path $OutputDir) { throw "Choose a fresh output directory: $OutputDir" }
$out = (New-Item -ItemType Directory $OutputDir).FullName
$project = Join-Path $root 'cores/crypto/primitives'
New-Item -ItemType Directory (Join-Path $out 'sim') | Out-Null
Copy-Item (Join-Path $project 'sim/expected_report.mem') (Join-Path $out 'sim')
& python (Join-Path $project 'tools/gen_aes_composite_sbox.py') --output (Join-Path $out 'sbox_functions.vh')
if ($LASTEXITCODE -ne 0) { throw 'S-box algebra verification failed' }
$generated = (Get-Content (Join-Path $out 'sbox_functions.vh') -Raw).Trim()
$core = (Get-Content (Join-Path $project 'src/aes128_core.v') -Raw).Replace("`r`n","`n")
if (!$core.Contains($generated.Replace("`r`n","`n"))) { throw 'Core does not match verified generated S-box' }
& python (Join-Path $project 'tools/gen_aes_stress_vectors.py') --output (Join-Path $out 'aes_vectors.mem')
if ($LASTEXITCODE -ne 0) { throw 'Independent vector generation failed' }
$sources = @(Get-ChildItem (Join-Path $project 'src/*.v') | ForEach-Object FullName)
$tests = @{
    tb_aes128_core = 'tb_aes128_core PASS'
    tb_aes128_stress = 'AES_STRESS PASS'
    tb_aes128_rate_board = 'AES_RATE_BOARD PASS'
    tb_crypto_selftest = 'tb_crypto_selftest PASS'
    tb_top_uart_report = 'tb_top_uart_report PASS'
}
Push-Location $out
try {
    foreach ($name in ($tests.Keys | Sort-Object)) {
        & iverilog -g2012 -s $name -o "$name.vvp" @sources (Join-Path $project "sim/$name.v")
        if ($LASTEXITCODE -ne 0) { throw "Compile failed: $name" }
        $lines = @(& vvp "$name.vvp" 2>&1)
        $code = $LASTEXITCODE
        $lines | Set-Content "$name.log"
        $text = $lines -join "`n"
        if ($code -ne 0 -or $text -notmatch [regex]::Escape($tests[$name]) -or $text -match '\bFAIL\b|\bFATAL\b|\btimeout\b') {
            throw "Simulation failed: $name; see $out/$name.log"
        }
        Write-Host "PASS $name"
    }
} finally { Pop-Location }
Write-Host "PASS AES and crypto regression; evidence: $out"
