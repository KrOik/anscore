$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'env.ps1')

$project = Join-Path $env:SIPEED_TANG20K_ROOT 'cores\acceleration\snn_lstm'
$build   = Join-Path $project 'build_sim'
New-Item -ItemType Directory -Force -Path $build | Out-Null

$ossBin = Join-Path $env:SIPEED_TANG20K_ROOT 'tools\oss-cad-suite\oss-cad-suite\bin'
$ossLib = Join-Path $env:SIPEED_TANG20K_ROOT 'tools\oss-cad-suite\oss-cad-suite\lib'
$env:PATH = "$ossBin;$ossLib;$env:PATH"

function Invoke-Step {
    param([string]$Name, [string]$Expect, [scriptblock]$Command)
    Write-Host "=== $Name ==="
    $log = Join-Path $build ($Name -replace '[^A-Za-z0-9]', '_') + '.log'
    $ErrorActionPreference = 'Continue'
    & $Command 2>&1 | ForEach-Object { $_.ToString() } | Tee-Object -FilePath $log
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($code -ne 0) { throw "$Name failed with exit code $code" }
    if ($Expect -and -not (Select-String -Path $log -Pattern $Expect -Quiet)) {
        throw "$Name did not report '$Expect' (see $log)"
    }
}

$rtl = @(
    'src/snn_param_rom.v', 'src/lstm_param_rom.v',
    'src/snn_event_loader.v', 'src/lstm_input_loader.v',
    'src/snn_sparse_conv_core.v', 'src/lstm_temporal_core.v',
    'src/uart_tx.v', 'src/board_report.v', 'src/top.v'
) | ForEach-Object { (Join-Path $project $_).Replace('\', '/') }

Push-Location $project
try {
    Invoke-Step -Name 'golden model' -Expect 'DENSE_VS_SPARSE PASS' -Command {
        python model/golden_all.py
    }

    Invoke-Step -Name 'iverilog dsp equiv' -Expect '^$' -Command {
        iverilog -g2012 -I sim -o build_sim/tb_equiv.vvp `
            sim/tb_mult12x12_equiv.v sim/mult12x12_model.v
    }
    Invoke-Step -Name 'vvp dsp equiv' -Expect 'MULT12X12 VS SMUL8 PASS' -Command {
        vvp build_sim/tb_equiv.vvp
    }

    Invoke-Step -Name 'iverilog snn core' -Expect '^$' -Command {
        iverilog -g2012 -I sim -o build_sim/tb_snn.vvp `
            sim/tb_snn_sparse_conv_core.v src/snn_sparse_conv_core.v `
            src/snn_event_loader.v src/snn_param_rom.v sim/mult12x12_model.v
    }
    Invoke-Step -Name 'vvp snn core' -Expect 'SNN TB PASS' -Command {
        vvp build_sim/tb_snn.vvp
    }

    Invoke-Step -Name 'iverilog lstm core' -Expect '^$' -Command {
        iverilog -g2012 -I sim -o build_sim/tb_lstm.vvp `
            sim/tb_lstm_temporal_core.v src/lstm_temporal_core.v `
            src/lstm_input_loader.v src/lstm_param_rom.v sim/mult12x12_model.v
    }
    Invoke-Step -Name 'vvp lstm core' -Expect 'LSTM TB PASS' -Command {
        vvp build_sim/tb_lstm.vvp
    }

    Invoke-Step -Name 'iverilog board top' -Expect '^$' -Command {
        iverilog -g2012 -I sim -o build_sim/tb_top.vvp sim/tb_top_uart.v `
            sim/mult12x12_model.v $rtl
    }
} finally {
    Pop-Location
}

# The UART capture TB reads its expected byte list from the sim directory.
Push-Location (Join-Path $project 'sim')
try {
    Invoke-Step -Name 'vvp board top' -Expect 'TOP UART PASS' -Command {
        vvp ../build_sim/tb_top.vvp
    }
} finally {
    Pop-Location
}

Write-Host 'SNN_LSTM_25K SIM SUITE PASS'
