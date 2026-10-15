$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'env.ps1')

$project = Join-Path $env:SIPEED_TANG20K_ROOT 'cores\acceleration\cnn_inference'
$build = Join-Path $project 'build_oss'
New-Item -ItemType Directory -Force -Path $build | Out-Null

$sources = Get-ChildItem (Join-Path $project 'src\*.v') |
    ForEach-Object { $_.FullName.Replace('\', '/') }
if (!$sources) {
    throw "No Verilog sources found under $project\src"
}
Write-Host "Sources: $($sources -join ' ')"

$json = (Join-Path $build 'top.json').Replace('\', '/')
$pnr = (Join-Path $build 'pnr.json').Replace('\', '/')
$fs = Join-Path $build 'cnn_infer_138k.fs'
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
    yosys -p "read_verilog $($sources -join ' '); synth_gowin -family gw5a -noalu -nodffe -top top -json $json; stat"
}

Invoke-NativeLogged -LogPath $pnrLog -Name 'nextpnr-himbaechel' -Command {
    nextpnr-himbaechel --json $json --write $pnr --device GW5AST-LV138FPG676AES --vopt family=GW5AST-138C --vopt cst=$cst --placer-heap-cell-placement-timeout 0 --placer-heap-beta 0.4 --placer-heap-alpha 0.08
}

& $ossPython $gowinPack -d GW5AST-138C -c -o $fs $pnr
if ($LASTEXITCODE -ne 0) {
    throw "gowin_pack failed with exit code $LASTEXITCODE"
}

Get-Item $fs | Select-Object FullName,Length
