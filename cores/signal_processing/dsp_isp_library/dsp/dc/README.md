# dc_stream

Reusable signed Q1.15 DC blocker, sliding-mean removal and slow baseline tracker.
Source: `rtl/dc_stream.sv`; full algorithm/interface/range contract: `SPEC.md`.
Metadata and precise evidence boundaries: `ip_manifest.json`.

Registered-output v3 is now the default source, SHA-256
`9f69a02caaa165d8136250421f252e95af39ec4f1daadd48a0cbc11d90a73f97`.
Mean N=1 emits {input,0} directly; larger means use signed26 arithmetic and
ties-even quantization. Blocker/baseline use fixed-width signed RNE and register
numerators before final output rounding/saturation. The sample-domain numerical
model is unchanged. Legacy latency1 source3237 is archived in
`legacy/latency1_3237f607/`; its pole65535 physical failures and all older images
remain preserved. The precise physical failure mechanism remains unproven.

Stream latency is two clocks and II=1, with two independently elastic slots.
An empty front slot accepts one sample while final output stalls; both occupied
and stalled stops all sample advancement. `output_ready=!m_valid||m_ready`;
`front_ready=!front_valid||output_ready`. This is not a single global-stall pipe.
Input is signed16; output high16 is baseline and low16 residual. `cfg_valid` holds
an atomic mode/pole/window tuple until both slots empty and `cfg_ready`; legal commit clears history,
illegal fields pulse error and preserve state. `rst_n` is synchronous active-low.

Run from repository root:

```
python cores/signal_processing/dsp_isp_library/dsp/dc/tests/test_models.py
python cores/signal_processing/dsp_isp_library/dsp/dc/tests/test_rtl.py
python cores/signal_processing/dsp_isp_library/dsp/dc/tests/test_mean_long.py
python cores/signal_processing/dsp_isp_library/dsp/dc/tests/replay_board_case.py
```

Default test latency is read from active `ip_manifest.json`; historical alternate
sources use explicit `--latency 1`, v3 alternates use `--latency 2`.

PASS: 144 floating/fixed cases; 24,000 protocol/numerical cycles; original physical
failure input replay. Dedicated long-window regression adds 6,053 cycles covering
W=1/2/16/256, each at least 3W+33 accepted samples per epoch, full-rate/random
stalls and reset with stale RAM retained. Preserved latency1 and v3 sources have
separate passing runs; earlier 233-cycle reconfiguration regression did **not** prove W=256 fill
or wrap and must not be interpreted that way.

Core-only synthesis: 1,592 LUT1–4, 263 FF, 3 MULT18X18, 1 DPX9B (132 wide
muxes separately). Qualified v3 UART wrapper: 2,107 routed LUT4, 3 DSP,
120.13 MHz final routed estimate; actual tested clock 27 MHz. This is not silicon
Fmax. Exact build identity and reproduction artifacts are linked in manifest.

Inspected physical verdicts and build hashes: two reprogrammed six-case boundary
runs, two reprogrammed five-case random runs, and the old failed mean host vector
all PASS. Coverage includes blocker/baseline poles0/65024/65535 and mean
windows1/8/16/64 with full-rate and backpressure. Window64
physical runs cover startup through first full window; W256 long-run is **only
simulation qualified**. Do not extrapolate to every pole or uninterrupted duration.
The promoted source equals the frozen candidate and source snapshot for image
`9c1ab9efe28268ee81591d0a242cc0d318577909bab01191075a4036e1348a90` byte-for-byte;
identity verification is in `evidence/promotion_20260925_035430_563461/`.
Source equality reuses the existing synthesis/image evidence without unnecessary
rebuilds. Default production UART integration and composed source simulation pass;
main independently reverified all23 physical reports and source identity in
`artifacts/dsp_isp_20260925/dc_delivery_audit_20260925_035911_615453.json`.
Standalone production acceptance is bounded to the documented configurations.
DSP chain hardware acceptance remains separate; no board operations were performed
by the DSP development subtask.
