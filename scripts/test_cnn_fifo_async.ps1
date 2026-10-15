param([Parameter(Mandatory=$true)][string]$OutputDir)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/env.ps1"
if (Test-Path -LiteralPath $OutputDir) { throw 'Use a fresh output directory.' }
New-Item -ItemType Directory -Path $OutputDir | Out-Null
$root = Split-Path $PSScriptRoot -Parent
foreach ($depth in @(2,4,16,64)) {
    foreach ($clocks in @(@(7,11),@(11,7),@(7,8))) {
        $stem = Join-Path $OutputDir "depth${depth}_w$($clocks[0])_r$($clocks[1])"
        & iverilog -g2012 -s tb_my_fifo_async -P "tb_my_fifo_async.DEPTH=$depth" -P "tb_my_fifo_async.WR_HALF=$($clocks[0])" -P "tb_my_fifo_async.RD_HALF=$($clocks[1])" -o "$stem.vvp" "$root/cores/acceleration/cnn_systolic/sim/tb_my_fifo_async.v" "$root/cores/acceleration/cnn_systolic/src/my_fifo.v" 2>&1 | Set-Content "$stem.compile.log"
        if ($LASTEXITCODE -ne 0) { throw "Compile failed: $stem" }
        & vvp "$stem.vvp" 2>&1 | Tee-Object "$stem.log"
        if ($LASTEXITCODE -ne 0) { throw "Simulation failed: $stem" }
        if (-not (Select-String -LiteralPath "$stem.log" -SimpleMatch 'PASS async FIFO')) { throw "Missing PASS: $stem" }
    }
}
