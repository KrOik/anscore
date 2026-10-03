# dc_stream

Reusable signed Q1.15 DC blocker, sliding-mean removal and slow baseline tracker.
Source: `rtl/dc_stream.sv`; full algorithm/interface/range contract: `SPEC.md`.
Metadata and precise evidence boundaries: `ip_manifest.json`.

**Open physical boundary failure:** source3237/candidate imagec503 passes the
bounded default-pole cases below, but blocker and baseline at pole65535 fail
physical boundary tests. Exact source replay passes, so the physical root cause
remains unresolved. This IP is not globally board-qualified or production
accepted. New diagnostic source is isolated under `candidates/fixed_width_round_v2/`.

The tested narrow-mean candidate is now the default source, SHA-256
`3237f6079941719789fc1c4cd3f3b2fe9366b6abdd179c0692f6d41140d89ddf`.
Mean N=1 emits {input,0} directly; larger means use signed26 arithmetic and
ties-even quantization. This matches the independent original numerical model.
The original source, failing captures and image remain preserved. The physical
root cause was not uniquely identified; a successful candidate is not proof of
a particular RAM or timing defect.

Stream latency is one clock and II=1; a single output slot propagates backpressure.
Input is signed16; output high16 is baseline and low16 residual. `cfg_valid` holds
an atomic mode/pole/window tuple until `cfg_ready`; legal commit clears history,
illegal fields pulse error and preserve state. `rst_n` is synchronous active-low.

Run from repository root:

```
python cores/signal_processing/dsp_isp_library/dsp/dc/tests/test_models.py
python cores/signal_processing/dsp_isp_library/dsp/dc/tests/test_rtl.py
python cores/signal_processing/dsp_isp_library/dsp/dc/tests/test_mean_long.py
python cores/signal_processing/dsp_isp_library/dsp/dc/tests/replay_board_case.py
```

PASS: 144 floating/fixed cases; 24,000 protocol/numerical cycles; original physical
failure input replay. Dedicated long-window regression adds 6,158 cycles covering
W=1/2/16/256, each at least 3W+33 accepted samples per epoch, full-rate/random
stalls and reset with stale RAM retained. Both preserved original and candidate
pass; earlier 233-cycle reconfiguration regression did **not** prove W=256 fill
or wrap and must not be interpreted that way.

Core-only synthesis: 2,035 LUT1–4, 192 FF, 3 MULT18X18, 1 DPX9B (179 wide
muxes separately). Qualified candidate UART wrapper: 2,560 routed LUT4, 3 DSP,
69.43 MHz final routed estimate; actual tested clock 27 MHz. This is not silicon
Fmax. Exact build identity and reproduction artifacts are linked in manifest.

Parent's physical sessions, inspected via verdicts and build hashes: two separate
programmed five-case runs PASS, plus 64-input full-rate blocker PASS. Coverage is
pole65024, mean windows1/8/64, blocker/baseline and configured stalls. Window64
physical runs cover startup through first full window; W256 long-run is **only
simulation qualified**. Do not extrapolate to every pole or uninterrupted duration.
Promoted-source final production package rebuild/requalification and DSP chain
acceptance remain open. No board operations were performed by this subtask.
