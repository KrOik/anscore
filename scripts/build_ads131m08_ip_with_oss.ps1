# Synthesise (and optionally place and route) the ADS131M08 multi-device IP.
#
#   -Board tang25k : GW5A-LV25MG121NES, 50 MHz system clock, family gw5a
#   -Board tang20k : GW2A-LV18PG256C8/I7, 27 MHz system clock, family gw2a
#   -AdcCount 1|2|4|8|16
#   -Route         : also run nextpnr + gowin_pack to produce a .fs
#
# The Tang Primer 25K flow needs two non-obvious settings, both verified here:
#   * nextpnr wants the FULL part number -- "GW5A-25A" fails with
#     "No package for partnumber";
#   * GW5A-25A forces SSPI-as-GPIO, and nextpnr and gowin_pack must agree on
#     that or gowin_pack aborts with "conflicting settings in nexpnr".
param(
    [ValidateSet('tang25k', 'tang20k')]
    [string]$Board = 'tang25k',
    [int]$AdcCount = 1,
    [switch]$Route
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'env.ps1')

if ($AdcCount -lt 1 -or $AdcCount -gt 16) { throw '-AdcCount must be 1..16' }

$project = Join-Path $env:SIPEED_TANG20K_ROOT 'cores\acquisition\ads131m08'
$rtl     = Join-Path $project 'rtl'
$build   = Join-Path $project 'build_oss'
New-Item -ItemType Directory -Force -Path $build | Out-Null

$sources = @(
    'ads131m08_spi_engine.v'
    'ads131m08_scheduler.v'
    'ads131m08_axi_lite.v'
    'ads131m08_sample_fifo.v'
    'ads131m08_regfile.v'
    'ads131m08_stream_adapter.v'
    'ads131m08_multi_ip.v'
) | ForEach-Object { (Join-Path $rtl $_).Replace('\', '/') }

# ads131m08_multi_ip is measured on its own for the resource report; the pad
# wrapper is the top for place and route, because the IP's 256-bit AXI-Stream
# port and full AXI4-Lite port make no sense as package pins.
$top = 'ads131m08_multi_ip'
if ($Route) {
    if ($Board -eq 'tang20k') {
        $top = 'ads131m08_pads_top_20k'
        $sources += (Join-Path $project 'src\ads131m08_pads_top_20k.v').Replace('\', '/')
    } else {
        $top = 'ads131m08_pads_top'
        $sources += (Join-Path $project 'src\ads131m08_pads_top.v').Replace('\', '/')
    }
}

switch ($Board) {
    'tang25k' {
        $family   = 'gw5a'
        $part     = 'GW5A-LV25MG121NES'
        $vfamily  = 'GW5A-25A'
        $packDev  = 'GW5A-25A'
        $freq     = 50
        $clkHz    = 50000000
        $cstName  = 'tang25k_ads131m08_16.cst'
        $extra    = @('--vopt', 'sspi_as_gpio')
        $packExtra = @('--sspi_as_gpio')
    }
    'tang20k' {
        $family   = 'gw2a'
        $part     = 'GW2A-LV18PG256C8/I7'
        $vfamily  = 'GW2A-18'
        $packDev  = 'GW2A-18'
        $freq     = 27
        $clkHz    = 27000000
        $cstName  = 'tang20k_ads131m08_ip.cst'
        $extra    = @()
        $packExtra = @()
    }
}

$tag   = "${Board}_n${AdcCount}"
$json  = (Join-Path $build "$tag.json").Replace('\', '/')
$pnr   = (Join-Path $build "$tag.pnr.json").Replace('\', '/')
$pnrLog = Join-Path $build "$tag.pnr.log"
$fs    = Join-Path $build "$tag.fs"
$cst   = (Join-Path $project "constr\$cstName").Replace('\', '/')
$stat  = Join-Path $build "$tag.stat.txt"
$meta  = Join-Path $build "$tag.build.json"

# Keep the selected top and build mode beside the generated netlist.  This is
# needed because a later synthesis-only run must not infer P&R state from an
# older .pnr.log or .fs file.  The metadata is disposable build output; it is
# consumed by manifest_ads131m08.ps1 to make the evidence unambiguous.
$buildMeta = [ordered]@{
    schema       = 'ads131m08-build-input-v1'
    generated    = (Get-Date).ToUniversalTime().ToString('o')
    board        = $Board
    adc_count    = $AdcCount
    mode         = if ($Route) { 'pnr' } else { 'synth' }
    top          = $top
    family       = $family
    part         = $part
    device       = $packDev
    target_mhz   = $freq
    clk_hz       = $clkHz
    constraint   = $cst
    constraint_role = if ($Board -eq 'tang25k') { 'reference-only' } else { 'route-checked-template' }
    sources      = $sources
}
$buildMeta | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 $meta

# ADC_COUNT / CLK_HZ are module parameters, not macros, so they must be forced
# with chparam; -D would silently leave every configuration at the default.
# The scalar 20K bring-up wrapper fixes ADC_COUNT at one and therefore only
# receives CLK_HZ here.
Write-Host "=== yosys: $tag ($family) ==="
$paramScript = if ($top -eq 'ads131m08_multi_ip') {
    "chparam -set ADC_COUNT $AdcCount -set CLK_HZ $clkHz $top; "
} else {
    "chparam -set CLK_HZ $clkHz $top; "
}
$yosysScript = "read_verilog $($sources -join ' '); " +
               $paramScript +
               "synth_gowin -family $family -top $top -json $json; " +
               "stat"
$out = yosys -p $yosysScript 2>&1
if ($LASTEXITCODE -ne 0) { $out | Select-Object -Last 12; throw "yosys failed for $tag" }
$out | Set-Content $stat
$out -split "`n" | Where-Object { $_ -match '^\s+\d+\s+(LUT4|DFF|DFFCE|DFFPE|DFFRE|BSRAM|MULT|SSRAM)\s*$' -or $_ -match '^\s+\d+\s+cells' } | ForEach-Object { $_.Trim() }

if ($Route) {
    Write-Host "=== nextpnr: $tag ($part) ==="
    $pnrArgs = @('--json', $json, '--write', $pnr, '--device', $part,
                 '--freq', "$freq", '--vopt', "family=$vfamily",
                 '--vopt', "cst=$cst") + $extra
    $pnrOut = nextpnr-himbaechel @pnrArgs 2>&1
    $pnrOut | Tee-Object -FilePath $pnrLog
    if ($LASTEXITCODE -ne 0) { throw "nextpnr failed for $tag" }

    Write-Host "=== gowin_pack: $tag ==="
    & $env:OSS_CAD_PYTHON `
        (Join-Path $env:SIPEED_TANG20K_ROOT 'tools\oss-cad-suite\oss-cad-suite\bin\gowin_pack-script.py') `
        -d $packDev @packExtra -o $fs $pnr
    if ($LASTEXITCODE -ne 0) { throw "gowin_pack failed for $tag" }
    Get-Item $fs | Select-Object FullName, Length
}

Write-Host "ADS131M08 IP build finished: $tag"
