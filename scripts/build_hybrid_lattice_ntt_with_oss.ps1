$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'env.ps1')

$project = Join-Path $env:SIPEED_TANG20K_ROOT 'cores\crypto\hybrid_lattice_ntt'
$build = Join-Path $project 'build_oss'
New-Item -ItemType Directory -Force -Path $build | Out-Null

$sources = @(
    'src/fused_butterfly.v',
    'src/ntt256_serial_core.v',
    'src/hybrid_lattice_op_scheduler.v',
    'src/ntt256_systolic_bank_mapper.v',
    'src/ntt256_systolic_issue_pipe.v',
    'src/ntt256_systolic_stream_selftest.v',
    'src/ntt256_systolic_arith_pipe.v',
    'src/ntt256_systolic_arith_selftest.v',
    'src/ntt256_systolic_state_equiv_monitor.v',
    'src/ntt256_systolic_full_stream_monitor.v',
    'src/hybrid_ntt256_selftest.v',
    'src/uart_tx.v',
    'src/top.v'
) | ForEach-Object { (Join-Path $project $_).Replace('\', '/') }

$json = (Join-Path $build 'top.json').Replace('\', '/')
$pnr = (Join-Path $build 'pnr.json').Replace('\', '/')
$fs = Join-Path $build 'hybrid_lattice_ntt_20k.fs'
$cst = (Join-Path $project 'src/top.cst').Replace('\', '/')
$yosysLog = Join-Path $build 'yosys.log'
$pnrLog = Join-Path $build 'nextpnr.log'
$gowinPack = Join-Path $env:SIPEED_TANG20K_ROOT 'tools\oss-cad-suite\oss-cad-suite\bin\gowin_pack-script.py'
$ossPython = $env:OSS_CAD_PYTHON

if (!(Test-Path $ossPython)) {
    throw "OSS CAD Suite python not found: $ossPython"
}

if (!(Test-Path $gowinPack)) {
    throw "gowin_pack script not found: $gowinPack"
}

function Invoke-NativeLogged {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogPath,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Command,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Command 2>&1 | ForEach-Object { $_.ToString() } | Tee-Object -FilePath $LogPath
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }

    if ($exitCode -ne 0) {
        throw "$Name failed with exit code $exitCode"
    }
}

Invoke-NativeLogged -LogPath $yosysLog -Name 'yosys' -Command {
    yosys -p "read_verilog $($sources -join ' '); synth_gowin -family gw2a -top top -json $json; stat"
}

Invoke-NativeLogged -LogPath $pnrLog -Name 'nextpnr-himbaechel' -Command {
    nextpnr-himbaechel --json $json --write $pnr --device GW2A-LV18PG256C8/I7 --vopt family=GW2A-18 --vopt cst=$cst
}

& $ossPython $gowinPack -d GW2A-18 -o $fs $pnr
if ($LASTEXITCODE -ne 0) {
    throw "gowin_pack failed with exit code $LASTEXITCODE"
}

& (Join-Path $PSScriptRoot 'report_hybrid_lattice_ntt_resources.ps1')
Get-Item $fs | Select-Object FullName,Length
