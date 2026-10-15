$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'env.ps1')

$project = Join-Path $env:SIPEED_TANG20K_ROOT 'cores\acceleration\snn_lstm'
$build   = Join-Path $project 'build_oss'
New-Item -ItemType Directory -Force -Path $build | Out-Null

$sources = @(
    'src/snn_param_rom.v', 'src/lstm_param_rom.v',
    'src/snn_event_loader.v', 'src/lstm_input_loader.v',
    'src/snn_sparse_conv_core.v', 'src/lstm_temporal_core.v',
    'src/uart_tx.v', 'src/board_report.v', 'src/top.v'
) | ForEach-Object { (Join-Path $project $_).Replace('\', '/') }

$json    = (Join-Path $build 'top.json').Replace('\', '/')
$pnr     = (Join-Path $build 'pnr.json').Replace('\', '/')
$fs      = Join-Path $build 'snn_lstm_25k.fs'
$cst     = (Join-Path $project 'src/top.cst').Replace('\', '/')
$yosysLog = Join-Path $build 'yosys.log'
$pnrLog   = Join-Path $build 'nextpnr.log'
$metrics  = Join-Path $build 'metrics.txt'
$gowinPack = Join-Path $env:SIPEED_TANG20K_ROOT 'tools\oss-cad-suite\oss-cad-suite\bin\gowin_pack-script.py'
$ossPython = $env:OSS_CAD_PYTHON
# MULT12X12 is instantiated by hand in lstm_temporal_core.v. Declaring the GW5A
# hard-IP cell library keeps yosys from sweeping the instance into fabric.
$gowinCells = (Join-Path $OssCadRoot 'share\yosys\gowin\cells_xtra_gw5a.v').Replace('\', '/')

if (!(Test-Path $ossPython))  { throw "OSS CAD Suite python not found: $ossPython" }
if (!(Test-Path $gowinPack))  { throw "gowin_pack script not found: $gowinPack" }
if (!(Test-Path $gowinCells)) { throw "GW5A cell library not found: $gowinCells" }

function Invoke-NativeLogged {
    param(
        [Parameter(Mandatory = $true)][string]$LogPath,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Command
    )
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Command 2>&1 | ForEach-Object { $_.ToString() } | Tee-Object -FilePath $LogPath
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
    if ($exitCode -ne 0) { throw "$Name failed with exit code $exitCode" }
}

Invoke-NativeLogged -LogPath $yosysLog -Name 'yosys' -Command {
    yosys -p "read_verilog $($sources -join ' '); read_verilog -lib $gowinCells; synth_gowin -family gw5a -top top -json $json; stat"
}

Invoke-NativeLogged -LogPath $pnrLog -Name 'nextpnr-himbaechel' -Command {
    nextpnr-himbaechel --json $json --write $pnr --device GW5A-LV25MG121NES --vopt family=GW5A-25A --vopt cst=$cst --vopt sspi_as_gpio
}

# NOTE: no -c here. -c emits a flash-compressed image, which openFPGALoader
# reports as loaded but leaves the GW5A running nothing. JTAG/SRAM programming
# needs the uncompressed bitstream.
& $ossPython $gowinPack -d GW5A-25A --sspi_as_gpio -o $fs $pnr
if ($LASTEXITCODE -ne 0) { throw "gowin_pack failed with exit code $LASTEXITCODE" }

$stat  = Select-String -Path $yosysLog -Pattern 'Cell Count' -Context 0,20 | Select-Object -First 1
$fmax  = Select-String -Path $pnrLog   -Pattern 'Max frequency|Worst-case|Timing' | Select-Object -Last 6
$size  = (Get-Item $fs).Length

@(
    "bitstream=$fs"
    "bytes=$size"
    "packed=uncompressed (JTAG SRAM)"
    ($stat.Context.PostContext -join "`n")
    ($fmax.Line -join "`n")
) | Set-Content -Path $metrics -Encoding ASCII

Write-Host "wrote $metrics"
Get-Content $metrics
