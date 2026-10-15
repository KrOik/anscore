$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'env.ps1')

$root = [string]$env:SIPEED_TANG20K_ROOT
$rtl = Join-Path $root 'cores\acquisition\ads131m08\rtl'
$source = Join-Path $rtl 'ads131m08_multi_ip.v'
$work = Join-Path ([System.IO.Path]::GetTempPath()) 'ads131m08-harness-fault'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$fixture = Join-Path $work 'broken_multi_ip.v'
$reportDir = Join-Path $root 'docs\quality\reports'
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null

try {
    $brokenText = (Get-Content -Raw $source) + "`nassign ;`n"
    $brokenText | Set-Content -Encoding UTF8 $fixture
    $output = iverilog -g2012 -tnull $fixture 2>&1
    $exitCode = $LASTEXITCODE
    $rejected = $exitCode -ne 0
    $result = [ordered]@{
        schema = 'ads131m08-fault-injection-report-v1'
        generated = (Get-Date).ToUniversalTime().ToString('o')
        status = if ($rejected) { 'PASS' } else { 'FAIL' }
        fixture = 'append invalid continuous assignment to a copied standalone top'
        expected_exit_nonzero = $true
        observed_exit_code = $exitCode
        compiler_rejected_fixture = $rejected
    }
    $result | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 (Join-Path $reportDir 'ads131m08-fault-injection.json')
    Write-Output "ADS131M08 FAULT INJECTION $($result.status) compiler_exit=$exitCode"
    if (-not $rejected) { throw 'Fault fixture unexpectedly compiled successfully' }
} finally {
    if (Test-Path $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}

exit 0
