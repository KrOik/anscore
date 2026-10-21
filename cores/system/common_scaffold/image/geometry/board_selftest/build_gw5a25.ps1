param(
    [switch]$SimOnly
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\..')).Path
. (Join-Path $root 'scripts\env.ps1')

$rtlDir = Join-Path $PSScriptRoot 'rtl'
$simDir = Join-Path $PSScriptRoot 'sim'
$cstPath = Join-Path $PSScriptRoot 'constr\tang25k_geometry_selftest.cst'
$inverseMap = Join-Path $PSScriptRoot '..\rtl\img_geo_inverse_map.v'
$selftestTop = Join-Path $rtlDir 'img_geo_inverse_map_board_selftest.v'
$testbench = Join-Path $simDir 'tb_img_geo_inverse_map_board_selftest.sv'

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$buildName = "build_gw5a25_${stamp}_$PID"
$build = Join-Path $PSScriptRoot $buildName
if (Test-Path -LiteralPath $build) {
    throw "Refusing to overwrite existing build evidence: $build"
}
New-Item -ItemType Directory -Path $build | Out-Null

$vvpPath = Join-Path $build 'board_selftest.vvp'
$iverilogLog = Join-Path $build 'iverilog.log'
$simulationLog = Join-Path $build 'simulation.log'
$yosysJson = (Join-Path $build 'board_selftest.json').Replace('\', '/')
$pnrJson = (Join-Path $build 'board_selftest.pnr.json').Replace('\', '/')
$cst = $cstPath.Replace('\', '/')
$yosysLog = Join-Path $build 'yosys.log'
$pnrLog = Join-Path $build 'nextpnr.log'
$packLog = Join-Path $build 'gowin_pack.log'
$fsPath = Join-Path $build 'geometry_inverse_map_25k.fs'
$gowinPack = Join-Path $root 'tools\oss-cad-suite\oss-cad-suite\bin\gowin_pack-script.py'

function Invoke-NativeLogged {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$LogPath,
        [Parameter(Mandatory=$true)][scriptblock]$Command
    )
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Command 2>&1 | ForEach-Object { $_.ToString() } | Tee-Object -FilePath $LogPath
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldPreference
    }
    if ($code -ne 0) {
        throw "$Name failed with exit code $code. Evidence: $LogPath"
    }
}

Write-Host "Build directory: $build"
Write-Host '=== Icarus simulation: 4x4 perspective coordinate self-test ==='
Invoke-NativeLogged -Name 'iverilog' -LogPath $iverilogLog -Command {
    iverilog -g2012 -s tb_img_geo_inverse_map_board_selftest -o $vvpPath $testbench $selftestTop $inverseMap
}
Invoke-NativeLogged -Name 'vvp' -LogPath $simulationLog -Command {
    vvp $vvpPath
}

if ($SimOnly) {
    Write-Host "SIM_ONLY PASS; build evidence: $build"
    return
}

if (!(Test-Path -LiteralPath $env:OSS_CAD_PYTHON)) {
    throw "OSS CAD Suite Python not found: $env:OSS_CAD_PYTHON"
}
if (!(Test-Path -LiteralPath $gowinPack)) {
    throw "gowin_pack script not found: $gowinPack"
}

$sources = @($inverseMap.Replace('\', '/'),$selftestTop.Replace('\', '/'))
$top = 'img_geo_inverse_map_board_selftest'
$yosysScript = "read_verilog -sv $($sources -join ' '); synth_gowin -family gw5a -top $top -json $yosysJson; stat"
Write-Host '=== GW5A synthesis ==='
Invoke-NativeLogged -Name 'yosys' -LogPath $yosysLog -Command {
    yosys -p $yosysScript
}

Write-Host '=== GW5A-25 place and route @ 50 MHz ==='
Invoke-NativeLogged -Name 'nextpnr-himbaechel' -LogPath $pnrLog -Command {
    nextpnr-himbaechel --json $yosysJson --write $pnrJson `
        --device GW5A-LV25MG121NES --freq 50 `
        --vopt family=GW5A-25A --vopt "cst=$cst" --vopt sspi_as_gpio
}

Write-Host '=== GW5A-25 bitstream packing ==='
Invoke-NativeLogged -Name 'gowin_pack' -LogPath $packLog -Command {
    # Keep the SRAM/JTAG image uncompressed; openFPGALoader cannot load -c output.
    & $env:OSS_CAD_PYTHON $gowinPack -d GW5A-25A --sspi_as_gpio -o $fsPath $pnrJson
}

$fsItem = Get-Item -LiteralPath $fsPath
$sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $fsPath).Hash
Write-Host "BITSTREAM PASS: $($fsItem.FullName) bytes=$($fsItem.Length) sha256=$sha256"
