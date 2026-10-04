# Four-stage CSC diagnostic candidate

Isolated candidate only: original `isp/csc_stream.v`, its golden and accepted
interface remain unchanged. User-requested timing diagnosis after physical
single-stage failures; no claim that root cause or physical repair is proven.

All 24 width/standard/range/operation configurations and Q16 coefficients are
unchanged. Stage1 registers independent low/high coefficient partial products
(bits0..8 versus bits9..18, signed bit18 subtraction); stage2 merges the two
parts exactly; stage3 sums three products and offset; stage4 rounds once and
saturates. No intermediate quantization, truncation or changed expected value.

Latency4 clocks and II1 when unstalled. Four transaction slots share a global
advance `!last_valid || m_tready`; when the final output is blocked, every
data/valid/SOF/EOL stage freezes and input ready is low. This conservative
global stall does not compact bubbles, and its ready path is combinational.
Config slot may accept while stalled if empty, but applies only on a real
accepted SOF. Simultaneous old-config commit/new-config reception retains the
original specified ordering. Atomic config never changes in-flight arithmetic:
partial products and offsets already reflect each pixel's accepted config.
Reset clears all valid/sideband/config state synchronously; arithmetic pipeline
registers need no reset because invalid pipeline contents are unobservable.
Each arithmetic stage updates only when its corresponding valid transaction
advances; invalid arithmetic payload holds. Valid/SOF/EOL still advance every
enabled cycle. The implementation uses combinational partial-product wires
outside the clocked process; earlier function-in-clock/always-updating variants
are archived under evidence and their superseded long UART runs remain saved.

`test_pipeline.py` supplies independent transaction/latency/config modeling,
24 numerical configurations, corners/every neutral level/random colors,
full-rate regions, bubbles/random ready/long stalls, in-flight reset,
simultaneous config replacement and config blockage. It checks each cycle and
rejects nine data/order/count/control/sideband mutations. It invokes real
Icarus. New evidence directories and hashes preserve each run.

```
python cores/signal_processing/dsp_isp_library/isp/candidates/pipeline4/test_pipeline.py
python cores/signal_processing/dsp_isp_library/board/block_harness/run.py --core csc --bits 8 --csc-source cores/signal_processing/dsp_isp_library/isp/candidates/pipeline4/csc_stream.v --latency 4 --build
```

Board protocol numerical words unchanged, but latency is explicitly bound in
variant.json, simulation_summary.json and build_summary.json. With stall0,
N inputs produce N outputs in N+4 RUN cycles. Old one-cycle images remain
N+1 and must be verified with the default latency1, never silently reinterpreted.

Latest direct 24-configuration regression:
`evidence/20260925_031129_508995/summary.json` PASS. Additional
`tb_invalid_x.sv` held all invalid input fields X for1000 clocks, then checked
known black recovery and20 cycles of stalled output stability; real Icarus
PASS in `evidence/invalid_x_20260925_031535/`.

CSC8 board candidate built (not physically accepted):
`board/block_harness/evidence/csc8_inferred_20260925_031306_002825/` relative
to the library root. Complete UART numerical/sideband/counter suite plus fault
tests PASS;4055 LUT,0 DSP, final tool timing73.64MHz at27MHz target.
Latency4. Raw UART TB now logs per-packet completion and periodic virtual time
so lack of output cannot be confused with confirmed simulation progress.

CSC10 also completed full UART/fault simulation and strict build in
`board/block_harness/evidence/csc10_inferred_20260925_031627_439716/`:
4703 LUT,0 DSP,66.93MHz final tool estimate, latency4. Both8/10-bit build
snapshots are byte-identical to the frozen candidate source SHA256
`0ecd8f6416ef31cdcce3b9557b7972a310bba88006a101ce3f0458d347e9237a`.
Source paths, mode, width, latency, source hashes and image hashes are saved
per build. Physical acceptance remains a separate parent-owned step.
