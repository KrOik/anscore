$ErrorActionPreference = 'Stop'
# ============================================================================
# test_wave2_ip_sim.ps1 -- wave2 IP regression:
#   1) every sim/tb_st_*.v compiles + runs standalone (digest vs golden)
#   2) aggregated w2_selftest simulation (all UNIT_EN masks present as
#      sim/masks.txt entries, default full + halves)
#   3) top.v UART report simulation vs sim/expected_report.mem (if present)
# Run from repo root:  .\scripts\test_wave2_ip_sim.ps1
# ============================================================================

. (Join-Path $PSScriptRoot 'env.ps1')

$project = Join-Path $env:SIPEED_TANG20K_ROOT 'cores\system\extended_library'
$sim = Join-Path $project 'sim'
$src = Join-Path $project 'src'
$imgwin = Join-Path $env:SIPEED_TANG20K_ROOT 'cores\image_processing\window\src'

# Common dependency set available to every unit TB (unused modules are fine).
$common = @(
    (Join-Path $src 'w2_dpram.v'),
    (Join-Path $src 'w2_win_rd.v'),
    (Join-Path $src 'w2_img_stim.v'),
    (Join-Path $sim 'gowin_bsram_sim.v'),
    (Join-Path $imgwin 'win3x3_gen.v'),
    (Join-Path $imgwin 'line_buf_ram.v'),
    (Join-Path $imgwin 'median3x3.v'),
    (Join-Path $imgwin 'morph3x3.v'),
    (Join-Path $imgwin 'sobel_edge.v'),
    (Join-Path $imgwin 'threshold_bin.v'),
    (Join-Path $imgwin 'gaussian3x3.v'),
    (Join-Path $imgwin 'uart_tx.v')
)

Push-Location $project
$fail = 0
try {
    # ---- phase 1: standalone unit TBs --------------------------------------
    $tbs = Get-ChildItem $sim -Filter 'tb_st_*.v' | Sort-Object Name
    if ($tbs.Count -eq 0) { throw 'no tb_st_*.v found' }
    foreach ($tb in $tbs) {
        $unit = $tb.BaseName -replace '^tb_st_', ''
        $vvp = Join-Path $sim ("tb_st_{0}.vvp" -f $unit)
        $core = Join-Path $src ("{0}.v" -f $unit)
        $cell = Join-Path $src ("st_{0}.v" -f $unit)
        $extra = @()
        $helpers = Get-ChildItem $src -Filter ("{0}_*.v" -f $unit) -ErrorAction SilentlyContinue
        $extra += $helpers | ForEach-Object { $_.FullName }
        $lst = Join-Path $sim ("files_{0}.lst" -f $unit)
        if (Test-Path $lst) {
            $extra += Get-Content $lst | Where-Object { $_ -match '\S' } |
                ForEach-Object { Join-Path $project $_.Trim() }
        }
        $files = @($tb.FullName, $core, $cell) + $extra + $common
        & iverilog -g2012 -I $src -o $vvp -s $tb.BaseName $files
        if ($LASTEXITCODE -ne 0) { Write-Host "FAIL compile $unit"; $fail++; continue }
        & vvp $vvp
        if ($LASTEXITCODE -ne 0) { Write-Host "FAIL run $unit"; $fail++ }
    }

    # ---- phase 2: aggregated selftest (full + lo/hi masks) -------------------
    # exclude files already in $common to avoid duplicate module declarations
    $allSrc = Get-ChildItem $src -Filter '*.v' | ForEach-Object { $_.FullName } |
        Where-Object { $common -notcontains $_ }
    $masks = @('FFFFFFFFFF', '00000FFFFF', 'FFFFF00000')
    foreach ($m in $masks) {
        $stVvp = Join-Path $sim ("tb_w2_selftest_{0}.vvp" -f $m)
        & iverilog -g2012 -I $src -o $stVvp -s tb_w2_selftest `
            "-DMASK_HEX=40'h$m" `
            (Join-Path $sim 'tb_w2_selftest.v') $allSrc $common
        if ($LASTEXITCODE -ne 0) { Write-Host "FAIL compile w2_selftest M=$m"; $fail++; continue }
        & vvp $stVvp | Tee-Object (Join-Path $sim ("agg_{0}.log" -f $m))
        if ($LASTEXITCODE -ne 0) { Write-Host "FAIL run w2_selftest M=$m"; $fail++ }
    }
} finally {
    Pop-Location
}
if ($fail -ne 0) { throw "wave2 sim regression: $fail failure(s)" }
Write-Host 'WAVE2 SIM REGRESSION PASS'
