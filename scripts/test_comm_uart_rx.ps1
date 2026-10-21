param([string]$OutputDir = '')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'env.ps1')
$root = $env:SIPEED_TANG20K_ROOT
if (!$OutputDir) { $OutputDir = Join-Path $root ('artifacts/uart_rx_' + (Get-Date -Format 'yyyyMMdd_HHmmss')) }
if (Test-Path $OutputDir) { throw "Use a new output directory: $OutputDir" }
$out = New-Item -ItemType Directory -Path $OutputDir
New-Item -ItemType Directory -Path (Join-Path $out.FullName 'sim') | Out-Null
$project = Join-Path $root 'cores/communication/primitives'
Copy-Item (Join-Path $project 'sim/expected_report.mem') (Join-Path $out.FullName 'sim')
$sources = @(Get-ChildItem (Join-Path $project 'src/*.v') | ForEach-Object FullName)
$models = Join-Path $project 'sim/gowin_sim_models.v'
$tests = @{
    tb_uart_rx_back_to_back = 'UART_BACK_TO_BACK PASS'
    tb_uart_rx_boundaries = 'UART_BOUNDARIES PASS'
    tb_uart_rx_stream_board = 'UART_STREAM_BOARD PASS'
    tb_comm_selftest = 'RESULT: PASS'
    tb_top_uart_report = 'tb_top_uart_report PASS'
}
Push-Location $out.FullName
try {
    foreach ($name in ($tests.Keys | Sort-Object)) {
        & iverilog -g2012 -s $name -o "$name.vvp" @sources $models (Join-Path $project "sim/$name.v")
        if ($LASTEXITCODE -ne 0) { throw "Compile failed: $name" }
        $lines = @(& vvp "$name.vvp" 2>&1)
        $code = $LASTEXITCODE
        $lines | Set-Content "$name.log"
        if ($code -ne 0 -or (($lines -join "`n") -notmatch [regex]::Escape($tests[$name])) -or
            (($lines -join "`n") -match 'FAIL|TIMEOUT|FATAL')) {
            throw "Simulation failed: $name (see $out/$name.log)"
        }
        Write-Host "PASS $name"
    }
    foreach ($unit in @('urx','spi','i2c','axil','fifo')) {
        $actual = (Get-Content "sim/dump_$unit.txt") -join "`n"
        $expected = (Get-Content (Join-Path $project "sim/golden_$unit.txt")) -join "`n"
        if ($actual -cne $expected) { throw "Golden stream differs: $unit" }
    }
    Write-Host "PASS all 5 golden streams; evidence: $out"
} finally { Pop-Location }
