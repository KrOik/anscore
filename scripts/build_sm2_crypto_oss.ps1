$ErrorActionPreference = 'Stop'
# Build the sm2_aes_crypto_20k board images with the OSS CAD Suite.
#
# The monolithic src/top.v (AES + full sm2_top protocol layer + SM3) maps to
# ~306% of the GW2A-18C LUT4 budget in nextpnr and cannot be placed, so the
# build produces two separate images:
#   -Image aes : src/top_aes.v  (aes_core + sm3_top, ~59% LUT4)
#   -Image sm2 : src/top_sm2.v  (sm2_ecc JAC_ONLY, BSRAM operand regfile;
#                 host hashes via the AES image / affine+modn on host)
#   -Image all : both (default)
param(
    [ValidateSet('aes', 'sm2', 'all')][string]$Image = 'all'
)

. (Join-Path $PSScriptRoot 'env.ps1')

$project = Join-Path $env:SIPEED_TANG20K_ROOT 'cores\crypto\sm2_aes'
$build = Join-Path $project 'build_oss'
New-Item -ItemType Directory -Force -Path $build | Out-Null

$shared = @(
    'src/uart_rx.v',
    'src/uart_tx.v'
)
$sm3 = @(
    'src/sm3/sm3_adder.v',
    'src/sm3/adder_32b.v',
    'src/sm3/csa_adder_3i_32b.v',
    'src/sm3/sm3_cmprss_ceil_comb.v',
    'src/sm3/sm3_cmprss_core.v',
    'src/sm3/sm3_expnd_core.v',
    'src/sm3/sm3_pad_core.v',
    'src/sm3/sm3_top.v'
)
$aes = @(
    'src/aes/aes_sbox.v',
    'src/aes/aes_inv_sbox.v',
    'src/aes/aes_key_mem.v',
    'src/aes/aes_encipher_block.v',
    'src/aes/aes_decipher_block.v',
    'src/aes/aes_core.v'
)
$sm2ecc = @(
    'src/sm2/mul_64b_wrapper.v',
    'src/sm2/mul_sos_256b_64x1_ir.v',
    'src/sm2/spd_mod_sub_stgb.v',
    'src/sm2/mul_add_sub_mod_module.v',
    'src/sm2/point_cal_top.v',
    'src/sm2/sm2_ecc.v',
    # sm2_mod_inv is only referenced by sm2_ecc's dead JAC_ONLY=1 generate
    # branch, but hierarchy -check still requires the module definition.
    'src/sm2/sm2_mod_inv.v'
)

$images = @{
    aes = @{
        Top     = 'top_aes'
        Sources = $shared + $aes + $sm3 + @('src/top_aes.v')
    }
    sm2 = @{
        Top     = 'top_sm2'
        Sources = $shared + $sm2ecc + @('src/top_sm2.v')
    }
}

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

function Build-Image {
    param([Parameter(Mandatory = $true)][string]$Name)

    $spec = $images[$Name]
    $top = $spec.Top
    $sources = $spec.Sources | ForEach-Object { (Join-Path $project $_).Replace('\', '/') }

    $json = (Join-Path $build "$top.json").Replace('\', '/')
    $pnr = (Join-Path $build "pnr_$top.json").Replace('\', '/')
    $fs = Join-Path $build "$top.fs"
    $cst = (Join-Path $project 'src/top.cst').Replace('\', '/')
    $sdc = (Join-Path $project 'src/top.sdc').Replace('\', '/')
    $yosysLog = Join-Path $build "yosys_$top.log"
    $pnrLog = Join-Path $build "nextpnr_$top.log"
    $gowinPack = Join-Path $env:SIPEED_TANG20K_ROOT 'tools\oss-cad-suite\oss-cad-suite\bin\gowin_pack-script.py'

    Invoke-NativeLogged -LogPath $yosysLog -Name 'yosys' -Command {
        yosys -q -p "read_verilog -I $($project.Replace('\','/'))/src/sm3 $($sources -join ' '); synth_gowin -top $top -json $json; stat"
    }

    Invoke-NativeLogged -LogPath $pnrLog -Name 'nextpnr-himbaechel' -Command {
        nextpnr-himbaechel --json $json --write $pnr --device GW2A-LV18PG256C8/I7 --vopt family=GW2A-18C --vopt cst=$cst --sdc $sdc
    }

    & $env:OSS_CAD_PYTHON $gowinPack -d GW2A-18C -o $fs $pnr
    if ($LASTEXITCODE -ne 0) { throw "gowin_pack failed with exit code $LASTEXITCODE" }

    Get-Item $fs | Select-Object FullName, Length
}

if ($Image -eq 'all') {
    Build-Image -Name 'aes'
    Build-Image -Name 'sm2'
} else {
    Build-Image -Name $Image
}
