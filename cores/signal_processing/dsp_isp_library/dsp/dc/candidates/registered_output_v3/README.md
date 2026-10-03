# Registered output v3 — isolated diagnostic candidate

Frozen source SHA-256:
`9f69a02caaa165d8136250421f252e95af39ec4f1daadd48a0cbc11d90a73f97`.
This frozen candidate was subsequently promoted after repeated bounded physical
qualification; see active `../../README.md` and manifest for current status.
The initial candidate-only evidence and reproduction commands below are preserved.

Compared with fixed-width v2, registers the two unquantized state numerators
before final RNE/saturation. Mean mode registers its already rounded integer
results and tags the bypass. Feedback state still updates only on accepted input
and preserves exactly the prior sample-domain model. Arithmetic range/RNE proof
is in `../fixed_width_round_v2/WIDTH_AUDIT.md`; no arithmetic formula changed.

The front slot and output slot each hold one transaction. Output-ready is
`!m_valid || m_ready`; front-ready is `!front_valid || output_ready`. If both
are occupied and downstream stalls, all sample state and held data remain fixed.
Front can accept one additional sample when only the final slot is occupied.
Configuration waits until **both** slots are empty; reset discards both.
No-stall transfer latency=2, II=1. This is an intentional interface timing change
from production latency1 and must be reflected in board/chain cycle oracles.

Verification commands from repository root:

```
python cores/signal_processing/dsp_isp_library/dsp/dc/tests/test_rtl.py cores/signal_processing/dsp_isp_library/dsp/dc/candidates/registered_output_v3/dc_stream.sv --latency 2
python cores/signal_processing/dsp_isp_library/dsp/dc/tests/test_mean_long.py cores/signal_processing/dsp_isp_library/dsp/dc/candidates/registered_output_v3/dc_stream.sv --latency 2
python cores/signal_processing/dsp_isp_library/dsp/dc/tests/replay_board_case.py cores/signal_processing/dsp_isp_library/dsp/dc/candidates/registered_output_v3/dc_stream.sv --latency 2 --case artifacts/dsp_isp_20260925/dc_baseline_boundaries_01/case_01
```

PASS: `../../evidence/rtl_20260925_034156_207891/summary.json`: 24000 cycles,
15744 output transfers, 103 configs, 26 reset edges,48 cross-product settings
and four negative checker fixtures. The two-stage cycle oracle independently
checks both-slot backpressure/config draining via expected ready/valid each cycle.
`../../evidence/mean_long_20260925_034202_392096/summary.json`: 6053 cycles,
W1/2/16/256, full-rate/random backpressure, each3W+33 inputs after retained-RAM reset.

Exact original mean failure, blocker pole65535 failure and baseline pole65535
failure host vectors all source-replay PASS; `*_replay.log` point to complete
new evidence directories. Baseline full-rate64 inputs takes66 replay cycles,
matching the independent two-slot cycle model. Physical failing source-v2 values
are retained in those reports as historical mismatches, not candidate observations.

Core-only `synth_gowin -noalu -family gw2a` PASS: 1592 LUT1–4,263 FF,
3 MULT18X18,1 DPX9B,132 extra wide muxes. `yosys.log`, `core.json` and
`resources.json` preserve exact tool/statistics. No routed/board resource claim.
The purpose is to isolate the output conversion path; the timing/root-cause
hypothesis still needs matched physical measurements.
