$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'env.ps1')

$project = Join-Path $env:SIPEED_TANG20K_ROOT 'cores\acquisition\micarray_doa'
$i2sOut = Join-Path $project 'sim\tb_i2s_quad_rx_stub.vvp'
$coreOut = Join-Path $project 'sim\tb_micarray_doa_core.vvp'
$spatialOut = Join-Path $project 'sim\tb_virtual_spatial_field.vvp'
$uartOut = Join-Path $project 'sim\tb_doa_uart_reporter.vvp'

iverilog -g2012 -o $i2sOut `
    (Join-Path $project 'sim\tb_i2s_quad_rx_stub.v') `
    (Join-Path $project 'src\i2s_quad_rx_stub.v')
if ($LASTEXITCODE -ne 0) {
    throw "iverilog failed for tb_i2s_quad_rx_stub with exit code $LASTEXITCODE"
}

vvp $i2sOut
if ($LASTEXITCODE -ne 0) {
    throw "vvp failed for tb_i2s_quad_rx_stub with exit code $LASTEXITCODE"
}

iverilog -g2012 -o $coreOut `
    (Join-Path $project 'sim\tb_micarray_doa_core.v') `
    (Join-Path $project 'src\micarray_doa_core.v')
if ($LASTEXITCODE -ne 0) {
    throw "iverilog failed for tb_micarray_doa_core with exit code $LASTEXITCODE"
}

vvp $coreOut
if ($LASTEXITCODE -ne 0) {
    throw "vvp failed for tb_micarray_doa_core with exit code $LASTEXITCODE"
}

iverilog -g2012 -o $spatialOut `
    (Join-Path $project 'sim\tb_virtual_spatial_field.v') `
    (Join-Path $project 'src\micarray_doa_core.v') `
    (Join-Path $project 'src\led_direction_filter.v')
if ($LASTEXITCODE -ne 0) {
    throw "iverilog failed for tb_virtual_spatial_field with exit code $LASTEXITCODE"
}

vvp $spatialOut
if ($LASTEXITCODE -ne 0) {
    throw "vvp failed for tb_virtual_spatial_field with exit code $LASTEXITCODE"
}

iverilog -g2012 -o $uartOut `
    (Join-Path $project 'sim\tb_doa_uart_reporter.v') `
    (Join-Path $project 'src\uart_tx.v') `
    (Join-Path $project 'src\doa_uart_reporter.v')
if ($LASTEXITCODE -ne 0) {
    throw "iverilog failed for tb_doa_uart_reporter with exit code $LASTEXITCODE"
}

vvp $uartOut
if ($LASTEXITCODE -ne 0) {
    throw "vvp failed for tb_doa_uart_reporter with exit code $LASTEXITCODE"
}

yosys -p "read_verilog $($project.Replace('\', '/'))/src/micarray_doa_core.v $($project.Replace('\', '/'))/src/led_direction_filter.v $($project.Replace('\', '/'))/src/sk9822_driver.v $($project.Replace('\', '/'))/src/i2s_quad_rx_stub.v $($project.Replace('\', '/'))/src/uart_tx.v $($project.Replace('\', '/'))/src/doa_uart_reporter.v $($project.Replace('\', '/'))/src/top.v; hierarchy -check -top top; proc; opt_clean; check"
if ($LASTEXITCODE -ne 0) {
    throw "yosys hierarchy check failed with exit code $LASTEXITCODE"
}
