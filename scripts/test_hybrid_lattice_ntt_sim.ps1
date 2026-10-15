$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'env.ps1')

$project = Join-Path $env:SIPEED_TANG20K_ROOT 'cores\crypto\hybrid_lattice_ntt'
$sim = Join-Path $project 'sim'
$butterflyOut = Join-Path $sim 'tb_fused_butterfly.vvp'
$maskedButterflyOut = Join-Path $sim 'tb_fused_butterfly_masked2.vvp'
$selftestOut = Join-Path $sim 'tb_hybrid_ntt_selftest.vvp'
$schedulerOut = Join-Path $sim 'tb_hybrid_lattice_op_scheduler.vvp'
$mlkemSchedulerOut = Join-Path $sim 'tb_mlkem768_flow_scheduler.vvp'
$mldsaSchedulerOut = Join-Path $sim 'tb_mldsa44_flow_scheduler.vvp'
$systolicOut = Join-Path $sim 'tb_ntt256_systolic_issue_pipe.vvp'
$zeroSwitchDescriptorOut = Join-Path $sim 'tb_hybrid_zero_switch_descriptor_sequencer.vvp'
$controlFlowRandomizerOut = Join-Path $sim 'tb_control_flow_randomizer.vvp'
$systolicArithOut = Join-Path $sim 'tb_ntt256_systolic_arith_pipe.vvp'
$systolicFullOut = Join-Path $sim 'tb_ntt256_systolic_full_stream.vvp'
$systolicFullMonitorOut = Join-Path $sim 'tb_ntt256_systolic_full_stream_monitor.vvp'
$systolicStateEquivOut = Join-Path $sim 'tb_ntt256_systolic_state_equiv.vvp'
$systolicStateArrayOut = Join-Path $sim 'tb_ntt256_systolic_state_array.vvp'
$systolicStateEquivMonitorOut = Join-Path $sim 'tb_ntt256_systolic_state_equiv_monitor.vvp'
$systolicChainedRoundtripOut = Join-Path $sim 'tb_ntt256_systolic_chained_roundtrip.vvp'
$systolicZeroSwitchChainOut = Join-Path $sim 'tb_ntt256_systolic_zero_switch_chain.vvp'
$ntt256Out = Join-Path $sim 'tb_ntt256_serial_core.vvp'
$topStatusOut = Join-Path $sim 'tb_top_status_report.vvp'
$topUartOut = Join-Path $sim 'tb_top_uart_report.vvp'

iverilog -g2012 -o $butterflyOut `
    (Join-Path $project 'sim\tb_fused_butterfly.v') `
    (Join-Path $project 'src\fused_butterfly.v')
if ($LASTEXITCODE -ne 0) {
    throw "iverilog failed for tb_fused_butterfly with exit code $LASTEXITCODE"
}

vvp $butterflyOut
if ($LASTEXITCODE -ne 0) {
    throw "vvp failed for tb_fused_butterfly with exit code $LASTEXITCODE"
}

iverilog -g2012 -s tb_fused_butterfly_masked2 -o $maskedButterflyOut `
    (Join-Path $project 'sim\tb_fused_butterfly_masked2.v') `
    (Join-Path $project 'src\fused_butterfly_masked2.v') `
    (Join-Path $project 'src\fused_butterfly.v')
if ($LASTEXITCODE -ne 0) {
    throw "iverilog failed for tb_fused_butterfly_masked2 with exit code $LASTEXITCODE"
}

vvp $maskedButterflyOut
if ($LASTEXITCODE -ne 0) {
    throw "vvp failed for tb_fused_butterfly_masked2 with exit code $LASTEXITCODE"
}

iverilog -g2012 -o $selftestOut `
    (Join-Path $project 'sim\tb_hybrid_ntt_selftest.v') `
    (Join-Path $project 'src\fused_butterfly.v') `
    (Join-Path $project 'src\hybrid_ntt_selftest.v')
if ($LASTEXITCODE -ne 0) {
    throw "iverilog failed for tb_hybrid_ntt_selftest with exit code $LASTEXITCODE"
}

vvp $selftestOut
if ($LASTEXITCODE -ne 0) {
    throw "vvp failed for tb_hybrid_ntt_selftest with exit code $LASTEXITCODE"
}

iverilog -g2012 -o $schedulerOut `
    (Join-Path $project 'sim\tb_hybrid_lattice_op_scheduler.v') `
    (Join-Path $project 'src\fused_butterfly.v') `
    (Join-Path $project 'src\ntt256_serial_core.v') `
    (Join-Path $project 'src\hybrid_lattice_op_scheduler.v')
if ($LASTEXITCODE -ne 0) {
    throw "iverilog failed for tb_hybrid_lattice_op_scheduler with exit code $LASTEXITCODE"
}

vvp $schedulerOut
if ($LASTEXITCODE -ne 0) {
    throw "vvp failed for tb_hybrid_lattice_op_scheduler with exit code $LASTEXITCODE"
}

iverilog -g2012 -o $mlkemSchedulerOut `
    (Join-Path $project 'sim\tb_mlkem768_flow_scheduler.v') `
    (Join-Path $project 'src\mlkem768_flow_scheduler.v')
if ($LASTEXITCODE -ne 0) {
    throw "iverilog failed for tb_mlkem768_flow_scheduler with exit code $LASTEXITCODE"
}

vvp $mlkemSchedulerOut
if ($LASTEXITCODE -ne 0) {
    throw "vvp failed for tb_mlkem768_flow_scheduler with exit code $LASTEXITCODE"
}

iverilog -g2012 -o $mldsaSchedulerOut `
    (Join-Path $project 'sim\tb_mldsa44_flow_scheduler.v') `
    (Join-Path $project 'src\mldsa44_flow_scheduler.v')
if ($LASTEXITCODE -ne 0) {
    throw "iverilog failed for tb_mldsa44_flow_scheduler with exit code $LASTEXITCODE"
}

vvp $mldsaSchedulerOut
if ($LASTEXITCODE -ne 0) {
    throw "vvp failed for tb_mldsa44_flow_scheduler with exit code $LASTEXITCODE"
}

iverilog -g2012 -o $systolicOut `
    (Join-Path $project 'sim\tb_ntt256_systolic_issue_pipe.v') `
    (Join-Path $project 'src\ntt256_systolic_bank_mapper.v') `
    (Join-Path $project 'src\ntt256_systolic_issue_pipe.v')
if ($LASTEXITCODE -ne 0) {
    throw "iverilog failed for tb_ntt256_systolic_issue_pipe with exit code $LASTEXITCODE"
}

vvp $systolicOut
if ($LASTEXITCODE -ne 0) {
    throw "vvp failed for tb_ntt256_systolic_issue_pipe with exit code $LASTEXITCODE"
}

iverilog -g2012 -s tb_hybrid_zero_switch_descriptor_sequencer -o $zeroSwitchDescriptorOut `
    (Join-Path $project 'sim\tb_hybrid_zero_switch_descriptor_sequencer.v') `
    (Join-Path $project 'src\hybrid_zero_switch_descriptor_sequencer.v') `
    (Join-Path $project 'src\ntt256_systolic_issue_pipe.v')
if ($LASTEXITCODE -ne 0) {
    throw "iverilog failed for tb_hybrid_zero_switch_descriptor_sequencer with exit code $LASTEXITCODE"
}

vvp $zeroSwitchDescriptorOut
if ($LASTEXITCODE -ne 0) {
    throw "vvp failed for tb_hybrid_zero_switch_descriptor_sequencer with exit code $LASTEXITCODE"
}

iverilog -g2012 -o $controlFlowRandomizerOut `
    (Join-Path $project 'sim\tb_control_flow_randomizer.v') `
    (Join-Path $project 'src\control_flow_randomizer.v')
if ($LASTEXITCODE -ne 0) {
    throw "iverilog failed for tb_control_flow_randomizer with exit code $LASTEXITCODE"
}

vvp $controlFlowRandomizerOut
if ($LASTEXITCODE -ne 0) {
    throw "vvp failed for tb_control_flow_randomizer with exit code $LASTEXITCODE"
}

iverilog -g2012 -o $systolicArithOut `
    (Join-Path $project 'sim\tb_ntt256_systolic_arith_pipe.v') `
    (Join-Path $project 'src\ntt256_systolic_arith_pipe.v')
if ($LASTEXITCODE -ne 0) {
    throw "iverilog failed for tb_ntt256_systolic_arith_pipe with exit code $LASTEXITCODE"
}

vvp $systolicArithOut
if ($LASTEXITCODE -ne 0) {
    throw "vvp failed for tb_ntt256_systolic_arith_pipe with exit code $LASTEXITCODE"
}

iverilog -g2012 -s tb_ntt256_systolic_full_stream -o $systolicFullOut `
    (Join-Path $project 'sim\tb_ntt256_systolic_full_stream.v') `
    (Join-Path $project 'src\ntt256_systolic_bank_mapper.v') `
    (Join-Path $project 'src\ntt256_systolic_arith_pipe.v') `
    (Join-Path $project 'src\ntt256_systolic_full_stream_selftest.v')
if ($LASTEXITCODE -ne 0) {
    throw "iverilog failed for tb_ntt256_systolic_full_stream with exit code $LASTEXITCODE"
}

vvp $systolicFullOut
if ($LASTEXITCODE -ne 0) {
    throw "vvp failed for tb_ntt256_systolic_full_stream with exit code $LASTEXITCODE"
}

iverilog -g2012 -s tb_ntt256_systolic_full_stream_monitor -o $systolicFullMonitorOut `
    (Join-Path $project 'sim\tb_ntt256_systolic_full_stream_monitor.v') `
    (Join-Path $project 'src\ntt256_systolic_bank_mapper.v') `
    (Join-Path $project 'src\ntt256_systolic_full_stream_monitor.v')
if ($LASTEXITCODE -ne 0) {
    throw "iverilog failed for tb_ntt256_systolic_full_stream_monitor with exit code $LASTEXITCODE"
}

vvp $systolicFullMonitorOut
if ($LASTEXITCODE -ne 0) {
    throw "vvp failed for tb_ntt256_systolic_full_stream_monitor with exit code $LASTEXITCODE"
}

iverilog -g2012 -s tb_ntt256_systolic_state_equiv -o $systolicStateEquivOut `
    (Join-Path $project 'sim\tb_ntt256_systolic_state_equiv.v') `
    (Join-Path $project 'src\ntt256_systolic_bank_mapper.v') `
    (Join-Path $project 'src\ntt256_systolic_arith_pipe.v')
if ($LASTEXITCODE -ne 0) {
    throw "iverilog failed for tb_ntt256_systolic_state_equiv with exit code $LASTEXITCODE"
}

vvp $systolicStateEquivOut
if ($LASTEXITCODE -ne 0) {
    throw "vvp failed for tb_ntt256_systolic_state_equiv with exit code $LASTEXITCODE"
}

iverilog -g2012 -s tb_ntt256_systolic_state_array -o $systolicStateArrayOut `
    (Join-Path $project 'sim\tb_ntt256_systolic_state_array.v') `
    (Join-Path $project 'src\ntt256_systolic_bank_mapper.v') `
    (Join-Path $project 'src\ntt256_systolic_arith_pipe.v') `
    (Join-Path $project 'src\ntt256_systolic_state_array.v')
if ($LASTEXITCODE -ne 0) {
    throw "iverilog failed for tb_ntt256_systolic_state_array with exit code $LASTEXITCODE"
}

vvp $systolicStateArrayOut
if ($LASTEXITCODE -ne 0) {
    throw "vvp failed for tb_ntt256_systolic_state_array with exit code $LASTEXITCODE"
}

iverilog -g2012 -s tb_ntt256_systolic_state_equiv_monitor -o $systolicStateEquivMonitorOut `
    (Join-Path $project 'sim\tb_ntt256_systolic_state_equiv_monitor.v') `
    (Join-Path $project 'src\ntt256_systolic_bank_mapper.v') `
    (Join-Path $project 'src\ntt256_systolic_arith_pipe.v') `
    (Join-Path $project 'src\ntt256_systolic_state_equiv_monitor.v')
if ($LASTEXITCODE -ne 0) {
    throw "iverilog failed for tb_ntt256_systolic_state_equiv_monitor with exit code $LASTEXITCODE"
}

vvp $systolicStateEquivMonitorOut
if ($LASTEXITCODE -ne 0) {
    throw "vvp failed for tb_ntt256_systolic_state_equiv_monitor with exit code $LASTEXITCODE"
}

iverilog -g2012 -s tb_ntt256_systolic_chained_roundtrip -o $systolicChainedRoundtripOut `
    (Join-Path $project 'sim\tb_ntt256_systolic_chained_roundtrip.v') `
    (Join-Path $project 'src\ntt256_systolic_bank_mapper.v') `
    (Join-Path $project 'src\ntt256_systolic_arith_pipe.v') `
    (Join-Path $project 'src\ntt256_systolic_state_array.v')
if ($LASTEXITCODE -ne 0) {
    throw "iverilog failed for tb_ntt256_systolic_chained_roundtrip with exit code $LASTEXITCODE"
}

vvp $systolicChainedRoundtripOut
if ($LASTEXITCODE -ne 0) {
    throw "vvp failed for tb_ntt256_systolic_chained_roundtrip with exit code $LASTEXITCODE"
}

iverilog -g2012 -s tb_ntt256_systolic_zero_switch_chain -o $systolicZeroSwitchChainOut `
    (Join-Path $project 'sim\tb_ntt256_systolic_zero_switch_chain.v') `
    (Join-Path $project 'src\hybrid_zero_switch_descriptor_sequencer.v') `
    (Join-Path $project 'src\hybrid_descriptor_bridge.v') `
    (Join-Path $project 'src\ntt256_systolic_bank_mapper.v') `
    (Join-Path $project 'src\ntt256_systolic_arith_pipe.v') `
    (Join-Path $project 'src\ntt256_systolic_state_array.v')
if ($LASTEXITCODE -ne 0) {
    throw "iverilog failed for tb_ntt256_systolic_zero_switch_chain with exit code $LASTEXITCODE"
}

vvp $systolicZeroSwitchChainOut
if ($LASTEXITCODE -ne 0) {
    throw "vvp failed for tb_ntt256_systolic_zero_switch_chain with exit code $LASTEXITCODE"
}

iverilog -g2012 -o $ntt256Out `
    (Join-Path $project 'sim\tb_ntt256_serial_core.v') `
    (Join-Path $project 'src\fused_butterfly.v') `
    (Join-Path $project 'src\ntt256_serial_core.v') `
    (Join-Path $project 'src\hybrid_lattice_op_scheduler.v') `
    (Join-Path $project 'src\hybrid_ntt256_selftest.v')
if ($LASTEXITCODE -ne 0) {
    throw "iverilog failed for tb_ntt256_serial_core with exit code $LASTEXITCODE"
}

vvp $ntt256Out
if ($LASTEXITCODE -ne 0) {
    throw "vvp failed for tb_ntt256_serial_core with exit code $LASTEXITCODE"
}

iverilog -g2012 -s tb_top_status_report -o $topStatusOut `
    (Join-Path $project 'sim\tb_top_status_report.v') `
    (Join-Path $project 'src\fused_butterfly.v') `
    (Join-Path $project 'src\ntt256_serial_core.v') `
    (Join-Path $project 'src\hybrid_lattice_op_scheduler.v') `
    (Join-Path $project 'src\ntt256_systolic_bank_mapper.v') `
    (Join-Path $project 'src\ntt256_systolic_issue_pipe.v') `
    (Join-Path $project 'src\ntt256_systolic_stream_selftest.v') `
    (Join-Path $project 'src\ntt256_systolic_arith_pipe.v') `
    (Join-Path $project 'src\ntt256_systolic_arith_selftest.v') `
    (Join-Path $project 'src\ntt256_systolic_state_equiv_monitor.v') `
    (Join-Path $project 'src\ntt256_systolic_full_stream_monitor.v') `
    (Join-Path $project 'src\hybrid_ntt256_selftest.v') `
    (Join-Path $project 'src\uart_tx.v') `
    (Join-Path $project 'src\top.v')
if ($LASTEXITCODE -ne 0) {
    throw "iverilog failed for tb_top_status_report with exit code $LASTEXITCODE"
}

vvp $topStatusOut
if ($LASTEXITCODE -ne 0) {
    throw "vvp failed for tb_top_status_report with exit code $LASTEXITCODE"
}

iverilog -g2012 -s tb_top_uart_report -o $topUartOut `
    (Join-Path $project 'sim\tb_top_uart_report.v') `
    (Join-Path $project 'src\fused_butterfly.v') `
    (Join-Path $project 'src\ntt256_serial_core.v') `
    (Join-Path $project 'src\hybrid_lattice_op_scheduler.v') `
    (Join-Path $project 'src\ntt256_systolic_bank_mapper.v') `
    (Join-Path $project 'src\ntt256_systolic_issue_pipe.v') `
    (Join-Path $project 'src\ntt256_systolic_stream_selftest.v') `
    (Join-Path $project 'src\ntt256_systolic_arith_pipe.v') `
    (Join-Path $project 'src\ntt256_systolic_arith_selftest.v') `
    (Join-Path $project 'src\ntt256_systolic_state_equiv_monitor.v') `
    (Join-Path $project 'src\ntt256_systolic_full_stream_monitor.v') `
    (Join-Path $project 'src\hybrid_ntt256_selftest.v') `
    (Join-Path $project 'src\uart_tx.v') `
    (Join-Path $project 'src\top.v')
if ($LASTEXITCODE -ne 0) {
    throw "iverilog failed for tb_top_uart_report with exit code $LASTEXITCODE"
}

vvp $topUartOut
if ($LASTEXITCODE -ne 0) {
    throw "vvp failed for tb_top_uart_report with exit code $LASTEXITCODE"
}

$root = $project.Replace('\', '/')
yosys -p "read_verilog $root/src/fused_butterfly.v $root/src/fused_butterfly_masked2.v $root/src/ntt256_serial_core.v $root/src/hybrid_lattice_op_scheduler.v $root/src/mlkem768_flow_scheduler.v $root/src/mldsa44_flow_scheduler.v $root/src/ntt256_systolic_bank_mapper.v $root/src/ntt256_systolic_issue_pipe.v $root/src/hybrid_zero_switch_descriptor_sequencer.v $root/src/control_flow_randomizer.v $root/src/ntt256_systolic_stream_selftest.v $root/src/ntt256_systolic_full_stream_selftest.v $root/src/ntt256_systolic_arith_pipe.v $root/src/ntt256_systolic_arith_selftest.v $root/src/ntt256_systolic_state_array.v $root/src/hybrid_descriptor_bridge.v $root/src/ntt256_systolic_state_equiv_monitor.v $root/src/ntt256_systolic_full_stream_monitor.v $root/src/hybrid_ntt256_selftest.v $root/src/uart_tx.v $root/src/top.v; hierarchy -check -top top; proc; opt_clean; check"
if ($LASTEXITCODE -ne 0) {
    throw "yosys hierarchy check failed with exit code $LASTEXITCODE"
}
