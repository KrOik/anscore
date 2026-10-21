param(
    # Selftest unit mask: 0x00FF = units 0-7, 0xFF00 = units 8-15,
    # 0xFFFF = all (full harness does not fit GW2A-18C placement).
    [string]$UnitMask = '00FF'
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'env.ps1')

$project = Join-Path $env:SIPEED_TANG20K_ROOT 'cores\acceleration\cnn_systolic'
$build = Join-Path $project 'build_oss'
New-Item -ItemType Directory -Force -Path $build | Out-Null

# mem files (pepage_weight.mem, bias_test.mem, ...) live in the project root;
# run yosys from there so $readmemh/$readmemb resolve.
Push-Location $project
try {
    $sources = @(
        'src/pe.v',
        'src/pe_col.v',
        'src/pe_page.v',
        'src/d_manager.v',
        'src/w_manager.v',
        'src/sdp_ram.v',
        'src/my_fifo.v',
        'src/max_pool2d.v',
        'src/activation_lut.v',
        'src/input_layer.v',
        'src/output_layer.v',
        'src/layer.v',
        'src/extrema_finder.v',
        'src/lprnet_spatial_sum.v',
        'src/lprnet_post_process.v',
        'src/cnn_selftest.v',
        'src/uart_tx.v',
        'src/top.v'
    ) | ForEach-Object { (Join-Path $project $_).Replace('\', '/') }

    $tag = "m$($UnitMask.ToLower())"
    $json = (Join-Path $build "top_$tag.json").Replace('\', '/')
    $pnr = (Join-Path $build "pnr_$tag.json").Replace('\', '/')
    $fs = Join-Path $build "cnn_systolic_20k_$tag.fs"
    $cst = (Join-Path $project 'src/top.cst').Replace('\', '/')
    $yosysLog = Join-Path $build "yosys_$tag.log"
    $pnrLog = Join-Path $build "nextpnr_$tag.log"
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
        yosys -p "read_verilog -sv $($sources -join ' '); chparam -set UNIT_EN 16'h$UnitMask top; synth_gowin -family gw2a -top top -json $json; stat"
    }

    Invoke-NativeLogged -LogPath $pnrLog -Name 'nextpnr-himbaechel' -Command {
        nextpnr-himbaechel --json $json --write $pnr --device GW2A-LV18PG256C8/I7 --vopt family=GW2A-18 --vopt cst=$cst
    }

    & $ossPython $gowinPack -d GW2A-18 -o $fs $pnr
    if ($LASTEXITCODE -ne 0) {
        throw "gowin_pack failed with exit code $LASTEXITCODE"
    }
} finally {
    Pop-Location
}

& (Join-Path $PSScriptRoot 'report_cnn_systolic_20k_resources.ps1')
Get-Item $fs | Select-Object FullName,Length
