# CIC isolated optimization candidate

`case_v3` passes the existing public CIC adapter regression at four original parameter configurations plus RATE=3/STAGES=3/SHIFT=4, and a backpressure-aware core scoreboard at all four original core parameter combinations plus RATE=3/STAGES=3/ACC_W=14. Ten configurations cover exact arithmetic, partial last, CE, output stalls, resets, tag/error responses and command poisoning. Independent binomial checkpoint oracle remains unchanged.

The original core test fixture precomputes source consumption using original one-cycle readiness; it cannot be replayed unchanged after a latency change. Its original files were preserved. `tb_cic_pipeline.v` instead drives an adaptive valid/ready source and compares accepted samples to the same signed modular CIC recurrence. Public adapter tests use the existing unchanged TB and independent Python oracle.

Implementation retains one input per enabled cycle: add an input register, replace serial integral prefix additions with a balanced exact ACC_W modular tree, and register each comb subtraction. Outputs gain STAGES+1 enabled clocks of latency. Backpressure globally stalls pipeline/state. Packet last propagates through each comb stage and clears that stage's own history, preserving adjacent packets.

Production DSP RTL and shared generator were not changed. `stage_candidate.py` overlays only this isolated candidate file into a fresh case. `case_v1` and `case_v2` retain their real setup-failure evidence. `case_v3` reports 77.60/66.12 MHz: resource and 50 MHz setup gates PASS; hold remains UNPROVEN, so the build returns 1 and is not packed or programmed. No board pass is claimed.

Commands:

```powershell
python cores/system/common_scaffold/board/tang25k/acceptance48/rtl_dsp/cic_optimized/run_candidate_tests.py
python cores/system/common_scaffold/board/tang25k/acceptance48/rtl_dsp/cic_optimized/stage_candidate.py --output <new-directory> --verify
python cores/system/common_scaffold/board/tang25k/acceptance48/build_case.py <new-directory> --attempt frozen_seed3 --no-lutram
```

Temporary fixture/VVP files are automatically removed. Intentional source/netlist/route and small validation logs are retained.
