$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot 'env.ps1')

$project = Join-Path $env:SIPEED_TANG20K_ROOT 'cores\acceleration\cnn_inference'
$sim = Join-Path $project 'sim'
$build = Join-Path $project 'build_oss'
New-Item -ItemType Directory -Force -Path $build | Out-Null

$srcFiles = @(Get-ChildItem (Join-Path $project 'src\*.v') |
    ForEach-Object { $_.FullName })
$hasEngine = Test-Path (Join-Path $project 'src\cnn_engine.v')
$engineTb = Join-Path $sim 'tb_cnn_engine.v'
$topTb = Join-Path $sim 'tb_top_uart.v'

$global:failures = 0
$global:ranAny = $false

function Invoke-Sim {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$TbPath,
        [Parameter(Mandatory = $true)][string]$VvpPath
    )
    $out = $VvpPath
    Write-Host "=== iverilog $Name ==="
    iverilog -g2012 -o $out $TbPath $srcFiles
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "iverilog failed for $Name (exit $LASTEXITCODE)"
        $global:failures++
        return
    }
    Write-Host "=== vvp $Name ==="
    # run from the repo root so $readmemh "cores/acceleration/cnn_inference/mem/..."
    # paths resolve (same convention as cnn_engine.v)
    Push-Location $env:SIPEED_TANG20K_ROOT
    try {
        $lines = @(vvp $out 2>&1 | ForEach-Object { $_.ToString() })
    } finally {
        Pop-Location
    }
    $lines | ForEach-Object { Write-Host $_ }
    $global:ranAny = $true
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "vvp failed for $Name (exit $LASTEXITCODE)"
        $global:failures++
        return
    }
    if ($lines | Select-String -Pattern 'FAIL' -SimpleMatch) {
        $global:failures++
    }
}

if (!$hasEngine) {
    Write-Warning 'src\cnn_engine.v not present yet (engine task still in flight); skipping engine and top-level simulations.'
} else {
    if (Test-Path $engineTb) {
        Invoke-Sim -Name 'tb_cnn_engine' -TbPath $engineTb `
            -VvpPath (Join-Path $build 'tb_cnn_engine.vvp')
    } else {
        Write-Warning 'sim\tb_cnn_engine.v not found; skipping engine unit test.'
    }

    if (Test-Path $topTb) {
        Invoke-Sim -Name 'tb_top_uart' -TbPath $topTb `
            -VvpPath (Join-Path $build 'tb_top_uart.vvp')
    } else {
        Write-Warning 'sim\tb_top_uart.v not found; skipping top-level UART test.'
    }
}

if ($global:failures -gt 0) {
    Write-Host "CNN138K SIM: FAIL ($global:failures failure(s))"
    exit 1
} elseif (!$global:ranAny) {
    Write-Host 'CNN138K SIM: SKIP (nothing runnable yet)'
    exit 0
} else {
    Write-Host 'CNN138K SIM: PASS'
    exit 0
}
