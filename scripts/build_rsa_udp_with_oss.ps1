$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'env.ps1')

$project = Join-Path $env:SIPEED_TANG20K_ROOT 'cores\crypto\rsa_udp'
$build = Join-Path $project 'build_oss'
New-Item -ItemType Directory -Force -Path $build | Out-Null

$sources = @(
    'src/PLL_6M.v',
    'src/uart_tx.v',
    'src/uart_event_debug.sv',
    'src/eth_support.sv',
    'src/rsa_modmul.v',
    'src/rsa_modexp.v',
    'src/rsa_udp_min_endpoint.sv',
    'src/top.sv'
) | ForEach-Object { (Join-Path $project $_).Replace('\', '/') }

$json = (Join-Path $build 'top_min.json').Replace('\', '/')
$pnr = (Join-Path $build 'pnr_min.json').Replace('\', '/')
$fs = Join-Path $build 'rsa_udp_20k.fs'
$cst = (Join-Path $project 'src/top.cst').Replace('\', '/')
$yosysLog = Join-Path $build 'yosys.log'
$pnrLog = Join-Path $build 'nextpnr.log'
$gowinPack = Join-Path $env:SIPEED_TANG20K_ROOT 'tools\oss-cad-suite\oss-cad-suite\bin\gowin_pack-script.py'
$ossPython = $env:OSS_CAD_PYTHON

function Invoke-NativeLogged {
    param(
        [Parameter(Mandatory = $true)][string]$LogPath,
        [Parameter(Mandatory = $true)][scriptblock]$Command,
        [Parameter(Mandatory = $true)][string]$Name
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
    yosys -q -p "read_verilog -sv $($sources -join ' '); synth_gowin -family gw2a -top top -json $json; stat"
}

Invoke-NativeLogged -LogPath $pnrLog -Name 'nextpnr-himbaechel' -Command {
    nextpnr-himbaechel --json $json --write $pnr --device GW2A-LV18PG256C8/I7 --vopt family=GW2A-18 --vopt cst=$cst
}

& $ossPython $gowinPack -d GW2A-18 -o $fs $pnr
if ($LASTEXITCODE -ne 0) { throw "gowin_pack failed with exit code $LASTEXITCODE" }

Get-Item $fs | Select-Object FullName,Length
