# CSC isolated implementation status

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
