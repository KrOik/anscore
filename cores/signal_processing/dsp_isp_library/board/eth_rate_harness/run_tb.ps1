# Compile and run the rmii_eth_pipe testbench with Icarus Verilog.
# Usage:  powershell -ExecutionPolicy Bypass -File run_tb.ps1
# Pass criterion: the last line of output is "ETHPIPE SIM PASS".
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here

# Locate the OSS CAD Suite bin directory (iverilog.exe / vvp.exe).
$candidates = @(
    "D:\sipeedTANG20K\tools\oss-cad-suite\oss-cad-suite\bin",
    "..\..\..\..\tools\oss-cad-suite\oss-cad-suite\bin"
)
$bin = $null
foreach ($c in $candidates) {
    if (Test-Path (Join-Path $c "iverilog.exe")) { $bin = (Resolve-Path $c).Path; break }
}
if (-not $bin) {
    $cmd = Get-Command iverilog -ErrorAction SilentlyContinue
    if ($cmd) { $bin = $cmd.Source | Split-Path -Parent }
}
if (-not $bin) { Write-Error "iverilog.exe not found; install OSS CAD Suite or fix PATH"; exit 2 }

# vvp.exe needs the DLLs that live in the suite's lib directory next to bin.
$lib = Join-Path (Split-Path -Parent $bin) "lib"
$env:PATH = "$bin;$lib;$env:PATH"

Write-Host "using iverilog from: $bin"
& (Join-Path $bin "iverilog.exe") -g2012 -Wall -o ethpipe.vvp `
    tb_rmii_eth_pipe.sv rmii_eth_pipe.sv eth_support.sv
if ($LASTEXITCODE -ne 0) { Write-Error "compile failed"; exit $LASTEXITCODE }

& (Join-Path $bin "vvp.exe") ethpipe.vvp
exit $LASTEXITCODE
