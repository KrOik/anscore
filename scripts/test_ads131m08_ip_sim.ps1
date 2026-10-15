# Simulation regression for the ADS131M08 multi-device IP.
#
#   multi : tb_ads131m08_multi_ip - N devices on a shared bus, CS exclusivity,
#                                   per-device configuration, sample routing,
#                                   round robin vs DRDY-priority scheduling.
#                                   Compiled for N = 1, 2, 4 and 16.
#   axi   : tb_ads131m08_axi      - AXI4-Lite register access, AXI4-Stream
#                                   back-pressure, FIFO overflow accounting.
#   legacy: the original single-device regressions in the 20K project, which
#           now share the extracted SPI PHY.
param(
    [ValidateSet('all', 'multi', 'axi', 'legacy')]
    [string]$Test = 'all',
    [ValidateRange(1, 3600)]
    [int]$TimeoutSeconds = 300,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'env.ps1')

$project = Join-Path $env:SIPEED_TANG20K_ROOT 'cores\acquisition\ads131m08'
$rtl     = Join-Path $project 'rtl'
$sim     = Join-Path $project 'sim'
New-Item -ItemType Directory -Force -Path $sim | Out-Null

$rtlSources = @(
    'ads131m08_spi_engine.v'
    'ads131m08_scheduler.v'
    'ads131m08_axi_lite.v'
    'ads131m08_sample_fifo.v'
    'ads131m08_regfile.v'
    'ads131m08_stream_adapter.v'
    'ads131m08_multi_ip.v'
) | ForEach-Object { (Join-Path $rtl $_).Replace('\', '/') }

$modelSource = (Join-Path $sim 'ads131m08_device_model.v').Replace('\', '/')

function Invoke-Sim {
    param([string]$Name, [string[]]$Sources, [string]$Top, [string]$Defines = '')

    $vvp = (Join-Path $sim "$Name.vvp").Replace('\', '/')
    Write-Host "=== building $Name ==="
    $defArgs = @()
    if ($Defines) { $defArgs = $Defines.Split(' ') }
    iverilog -g2012 "-I$sim" @defArgs -o $vvp -s $Top @Sources
    if ($LASTEXITCODE -ne 0) { throw "iverilog failed for $Name" }

    $stdoutPath = Join-Path $sim "$Name.stdout.log"
    $stderrPath = Join-Path $sim "$Name.stderr.log"
    $vvpCommand = (Get-Command vvp -ErrorAction Stop).Source
    $process = Start-Process -FilePath $vvpCommand -ArgumentList @($vvp) `
        -WorkingDirectory $project -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath -PassThru
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $process.Kill()
        $process.WaitForExit()
        throw "$Name timed out after $TimeoutSeconds seconds"
    }

    $stdout = if (Test-Path $stdoutPath) { Get-Content -Raw $stdoutPath } else { '' }
    $stderr = if (Test-Path $stderrPath) { Get-Content -Raw $stderrPath } else { '' }
    if ($Quiet) {
        @($stdout -split "`r?`n"; $stderr -split "`r?`n") |
            Where-Object { $_ -match 'PASS|FAIL|ERROR|finished|timeout|sweep done|streamed|drops' } |
            ForEach-Object { Write-Host $_ }
    } else {
        if ($stdout) { Write-Host $stdout.TrimEnd() }
        if ($stderr) { Write-Host $stderr.TrimEnd() }
    }
    if ($process.ExitCode -ne 0) { throw "$Name failed (exit $($process.ExitCode))" }
}

if ($Test -eq 'all' -or $Test -eq 'multi') {
    foreach ($n in 1, 2, 4, 16) {
        Invoke-Sim -Name "tb_multi_n$n" `
            -Sources ($rtlSources + @($modelSource, (Join-Path $sim 'tb_ads131m08_multi_ip.v'))) `
            -Top 'tb_ads131m08_multi_ip' -Defines "-DTB_NDEV=$n"
    }
}

if ($Test -eq 'all' -or $Test -eq 'axi') {
    Invoke-Sim -Name 'tb_axi' `
        -Sources ($rtlSources + @($modelSource, (Join-Path $sim 'tb_ads131m08_axi.v'))) `
        -Top 'tb_ads131m08_axi'
}

if ($Test -eq 'all' -or $Test -eq 'legacy') {
    & (Join-Path $PSScriptRoot 'test_spi_lcd_sim.ps1') -Test adc
    if ($LASTEXITCODE -ne 0) { throw 'legacy ADS131M08 regression failed' }
}

Write-Host 'ADS131M08 IP regression finished.'
