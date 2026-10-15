$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'env.ps1')

$root = [string]$env:SIPEED_TANG20K_ROOT
$formalDir = Join-Path $root 'cores\acquisition\ads131m08\formal'
$harness = Join-Path $formalDir 'ads131m08_formal_harness.sv'
$sbyFile = Join-Path $formalDir 'ads131m08.sby'
$sources = @(
    (Join-Path $root 'cores\acquisition\ads131m08\rtl\ads131m08_axi_lite.v'),
    (Join-Path $root 'cores\acquisition\ads131m08\rtl\ads131m08_sample_fifo.v'),
    (Join-Path $root 'cores\acquisition\ads131m08\rtl\ads131m08_spi_engine.v'),
    (Join-Path $root 'cores\acquisition\ads131m08\rtl\ads131m08_scheduler.v'),
    (Join-Path $root 'cores\acquisition\ads131m08\rtl\ads131m08_multi_ip.v'),
    (Join-Path $root 'cores\acquisition\ads131m08\rtl\ads131m08_regfile.v'),
    (Join-Path $root 'cores\acquisition\ads131m08\rtl\ads131m08_stream_adapter.v'),
    $harness
)
foreach ($path in @($harness, $sbyFile) + $sources) {
    if (-not (Test-Path $path -PathType Leaf)) { throw "Missing formal input: $path" }
}

$reportDir = Join-Path $root 'docs\quality\reports'
New-Item -ItemType Directory -Force $reportDir | Out-Null
$reportPath = Join-Path $reportDir 'ads131m08-formal.json'
$sby = Get-Command sby -ErrorAction SilentlyContinue
if ($sby) {
    & sby -f $sbyFile
    if ($LASTEXITCODE -ne 0) { throw "ADS131M08 formal proof failed ($LASTEXITCODE)" }
    $result = [ordered]@{
        schema = 'ads131m08-formal-report-v1'
        generated = (Get-Date).ToUniversalTime().ToString('o')
        status = 'PASS-BOUNDED'
        method = 'symbiyosys'
        sby = $sbyFile.Replace('\', '/')
        depth = 12
        proof_scope = 'bounded model check; unbounded induction is not claimed'
        board_evidence = 'DEFERRED'
    }
} else {
    $yosys = Get-Command yosys -ErrorAction SilentlyContinue
    if (-not $yosys) { throw 'Neither sby nor yosys is available for the formal fallback.' }
    $sourceArgs = ($sources | ForEach-Object { $_.Replace('\', '/') }) -join ' '
    $script = "read_verilog -formal -sv $sourceArgs; prep -top ads131m08_formal_harness"
    $fallbackOutput = yosys -p $script 2>&1
    $fallbackExit = $LASTEXITCODE
    $fallbackLog = Join-Path $reportDir 'ads131m08-formal-fallback.log'
    $fallbackOutput | Set-Content -Encoding UTF8 $fallbackLog
    if ($fallbackExit -ne 0) {
        $fallbackOutput | Select-Object -Last 40 | Out-Host
        throw "ADS131M08 formal fallback elaboration failed ($fallbackExit)"
    }
    $result = [ordered]@{
        schema = 'ads131m08-formal-report-v1'
        generated = (Get-Date).ToUniversalTime().ToString('o')
        status = 'DEFERRED'
        method = 'yosys-elaboration-fallback'
        sby = $sbyFile.Replace('\', '/')
        fallback_log = $fallbackLog.Replace('\', '/')
        reason = 'sby and an SMT solver are unavailable; elaboration is not a proof'
        board_evidence = 'DEFERRED'
    }
}
$result | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 $reportPath
$result | ConvertTo-Json -Depth 6
