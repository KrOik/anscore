# Resource closure (open)

Both earlier full builds are preserved as placement failures. The narrow-LUT
attempt board_20261020T195941640556Z needs24626/23040LUT4, so no resource or
timing closure is claimed. Automatic hard-DSP inference in the installed
synth_gowin flow supports GW1N/GW2A, not GW5A; no vendor DSP was substituted.

`lockin4` retains48-bit accumulators and the original sample cadence. Its
averaging now removes15fixed fractional bits before the variable shift:
`value >>> (15+shift)` and `$signed(value[47:15]) >>> shift` have identical
low16result bits. SAT proves all48-bit inputs/all16shift codes in
average_proof_20261020T2015088869463Z. Rerun after loading env.ps1:

```
yosys -p "read_verilog cores/signal_processing/lockin/tb/average_equivalence.v; prep -top average_equivalence; sat -verify -prove equal 1 -show-inputs"
```

Isolated average_mapping_20261020T201533551709Z maps112LUT3+5ALU before,
92LUT3+2LUT2+4LUT4 after. This small saving alone cannot close full-top size.
References/tolerances and state timing are unchanged.

The build now runs hierarchy/proc/flatten/opt/wreduce/booth before synth_gowin.
Booth changes multiplication implementation without changing clock boundaries.
An isolated17x17signed multiplier maps843LUT1..4/34ALU before versus
585LUT1..4/33ALU after with identical GW5A narrow-LUT options:
booth_mapping_20261020T201611834080Z. Full-top savings remain unproven.

`python cores/signal_processing/lockin/tools/test_booth.py` simulates actual
Booth+techmap lowered logic against5081Python integer products (signed edges
and seeded random vectors). booth_test_20261020T201711034135Z passes.
The first attempt failed because `$fa` internal cells lacked a simulation
model; adding techmap fixed that harness. The failure is retained.
This test is not full-top formal equivalence.

Lock-in/live/replay/control/UART regressions pass after the averaging edit.
Third frozen full build board_20261020T201758272933Z is running with Booth
and narrow LUTs. No new PPA or physical acceptance claim until actual reports.
