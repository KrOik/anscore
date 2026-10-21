# CSC production source qualification

The canonical `csc_stream.v` is now byte-identical to the qualified four-stage
candidate SHA256 `0ecd8f6416ef31cdcce3b9557b7972a310bba88006a101ce3f0458d347e9237a`.
Latency4, II1, global stall, four transaction slots; numeric/config contracts
unchanged. The one-cycle original and its documentation/test source are
archived in `legacy/one_cycle_904bbc03/` and remain testable with explicit
`--source .../csc_stream.v --latency 1` on test_csc_rtl.py.

`ip_manifest.json`, regenerated/checked by `python
cores/signal_processing/dsp_isp_library/isp/package_csc.py`, binds both exact-source board
builds to8/10-bit full12-configuration physical runs and reprogram repeats.
The original physical matrix uses one word for cfg0 and64 words for cfg1..11
with mixed stall patterns. Separate fullrate_01 physical runs cover every
configuration at64 words/stall0 and68 RUN cycles. This does not claim UART
operates at the core clock or arbitrary-resolution camera qualification.

After promotion, default24-configuration RTL regression PASS
`evidence/20260925_032401_924030/`; archived1-cycle24-configuration regression
PASS `evidence/20260925_032420_209129/`. Default board entry simulations pass
for CSC8/CSC10 (latency4), DC/identity (latency1); exact paths are in manifest.
Production source/evidence equality validation PASS. No same-source full
resynthesis was repeated, and no untested image is claimed: qualified wrapper
images remain4055/4703 LUT,0 DSP,73.64/66.93MHz final estimated timing.
Changed local docs/default latency policy and packaged manifests; shared
central requirement ledger and main physical runner were not modified.

Remaining boundary: standalone CSC qualification is complete for documented
8/10-bit configurations and bounded board cases. Representative ISP chain
integration, broader frame geometry testing and overall library acceptance
remain separate tasks. Core-only pipeline resource report is not extrapolated
from wrapper totals.

## Historical one-cycle isolated implementation (superseded)

2026-09-25: RTL, model and real Icarus protocol/numeric simulation PASS.
Isolated noalu Gowin synthesis PASS. No P&R, physical timing, board test or
production integration acceptance; do not mark CSC as fully delivered.

Files: csc_stream.v, generated csc_coeffs.vh, gen_csc_coeffs.py,
csc_model.py, test_csc_model.py, test_csc_rtl.py, synth_csc.py,
CSC_SPEC.md. Historical source/golden unchanged. No board access performed.

Commands from repository root:

```
python cores/signal_processing/dsp_isp_library/isp/test_csc_model.py
python cores/signal_processing/dsp_isp_library/isp/test_csc_rtl.py
python cores/signal_processing/dsp_isp_library/isp/synth_csc.py --bits 10
```

Independent float model: 24 configurations, 114360 vectors PASS, maximum
error 0.5161290322581635 code. RTL evidence:
`evidence/20260925_022517_183931/summary.json`, stimuli, cycle traces, compile
and vvp logs, source hashes. BITS=8: 7551 checked cycles, 6125 accepted input
transactions; BITS=10: 16734 cycles, 15341 accepted. Accepted counts include
transactions intentionally discarded by reset. Twelve configuration modes
per width. Six checker mutation classes per width rejected; BITS=9 rejected.

| Isolated synthesis (not P&R) | BITS=8 | BITS=10 |
|---|---:|---:|
| LUT1–4 sum | 3174 | 4002 |
| FF | 37 | 43 |
| MUX2_LUT5 (separate) | 259 | 311 |
| Gowin DSP / BRAM cells | 0 / 0 | 0 / 0 |

8-bit evidence: `evidence/20260925_022210_414287/synth8.log`, core8.json.
Exact yosys command was `read_verilog -Icores/signal_processing/dsp_isp_library/isp
cores/signal_processing/dsp_isp_library/isp/csc_stream.v; synth_gowin -top csc_stream -noalu;
stat; write_json cores/signal_processing/dsp_isp_library/isp/evidence/20260925_022210_414287/core8.json`.
10-bit evidence: `evidence/synth_20260925_022451_543991/` contains full
command.ys, synthesis.log, core.json and metrics/hashes summary. Synthesis
includes top I/O buffers; excludes external wrapper. Both resource counts
are below core-only 15K/4 DSP gates, but no board image gate is proven.
The combinational shift-add matrix precedes one elastic output register;
27 MHz timing needs route verification and may require extra pipeline stages.

Next: register-constrained P&R timing, pipelining if needed without reducing
II=1, then parent-controlled input/output board harness and repeat-program
qualification. No public per-pixel stream source is replaced by selftest.
