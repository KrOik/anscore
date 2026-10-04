# Synchronous raster window foundation

Isolated **VALID-region** 3x3/5x5 windows, 1..16-bit unsigned opaque samples,
positive compile-time WIDTH/HEIGHT. There is no dynamic configuration.
`stream_window_padded` adds selectable ZERO/REPLICATE borders using one additional
row buffer. These are window generators, not convolution/median algorithm cores.

`clk`, active-low synchronous `rst_n`; `s_*` and `m_*` Stream with one-bit SOF
`tuser` and EOL `tlast`. Input is WIDTH*HEIGHT raster-order pixels per frame.
The output is max(WIDTH-K+1,0) by max(HEIGHT-K+1,0); images smaller than K
produce no output. First output SOF identifies the first cropped window, and
output EOL identifies each cropped row end. Window word lane `row*K+col`,
starting at the least-significant lane, runs top-left to bottom-right.

Pixels are accepted independently of downstream ready when the output slot is
empty. Output data/valid/SOF/EOL hold on backpressure. One combinational ready
path reaches the input; put stream_sync_fifo RAM_DEPTH>=2 between long chains.
Global pipeline stalls preserve RAM read data and all horizontal state.
Input II=1 without stalls; window II=1 within the valid region, with K-1 cycles
of row fill. A completing input pixel transfers to the output two rising edges
later; startup consumes (K-1)*WIDTH+K pixels. Tail needs the pending read stage
and output handshake; no dummy input pixel is required. Multiple consecutive
frames need no drain or reset, but frame dimensions are fixed.

RAM has K banks of WIDTH*DATA_WIDTH bits: K-1 historical rows plus one
current-row scratch bank. This is explicitly **three/five rows**, not a claim
of minimum two/four physical rows. Reading all banks synchronously while writing
the current bank avoids using its read/write collision result. The oldest
needed row is a different bank. At row wrap the next current bank is discarded.
Only K*(K-1) horizontal pixels use registers. Memories and horizontal data are
not reset; valid row/column counters suppress stale data after reset. Reset
discards every in-flight input/window. `ram_style` is not physical mapping proof.

`marker_error` sticks on missing/unexpected SOF or EOL. It diagnoses malformed
markers while counters retain the configured raster boundaries; it is not an
automatic resynchronizer. Synchronous reset clears it. Illegal static parameters
are rejected at elaboration/simulation. No arithmetic, Q format, rounding or
numerical approximation is involved; the Python raster-slicing model is exact.

Reproduce from root:

```
python cores/signal_processing/dsp_isp_library/infra/window/test_window.py --output artifacts/dsp_isp_20260925/window_sim_NEW
```

Initial evidence: `artifacts/dsp_isp_20260925/window_sim_01/`: 8 configurations,
3 epochs with 3 frames each, continuous and seeded stalled transfers, held
payload checks, short dimensions, reset interruption with retained RAM, malformed
marker rejection, numerical checker mutation. No physical acceptance claimed.

## Row-buffered padding wrapper

`stream_window_padded` preserves the same data/Stream/marker-error ports. `PAD_MODE`
is 0 for ZERO and 1 for REPLICATE; `MAX_WIDTH` defaults to 4096 and rejects widths
above the explicitly selected capacity limit. K remains 3 or 5. Pixels outside
the original frame are zero, or the nearest edge pixel respectively. Outputs
are **WIDTH by HEIGHT centered windows**, including 1x1 and dimensions below K.
The center lane is `(K*K)/2`; lane packing remains top-left to bottom-right.

Architecture: source → one synchronous WIDTH-pixel row RAM → padded raster
replay → unchanged VALID K-bank window engine → output. The cache captures a full
source row, then issues WIDTH+K-1 extended pixels; left/right use zero or the
cached endpoint. The first/last cached row is replayed K/2 extra times to generate
top/bottom boundaries. ZERO uses those same virtual positions but substitutes zero.
No frame RAM, no unsynchronized read, no implicit coordinate wrap and no RAM reset.
Cache read/write never occur together. The existing core still uses K banks,
each WIDTH+K-1 pixels wide. Total memory bits:
`DATA_WIDTH * (WIDTH + K*(WIDTH+K-1))`, plus existing horizontal registers.

Input ready is low during row replay and final drain. Source valid must be held;
the wrapper does not require a source to wait for ready before asserting valid.
It accepts one input per clock during capture and emits one result per clock
**within each output row**, but cannot accept and emit entire frames at II=1.
Let `R=K/2`, `PW=WIDTH+K-1`, `PH=HEIGHT+K-1`. With uninterrupted valid/ready:

- First-output latency from the first accepted source pixel is
  `WIDTH*(1+min(R,HEIGHT-1)) + (K-1)*PW + K-1 + 4` cycles.
- Consecutive frame-start acceptance interval is
  `WIDTH*HEIGHT + PW*PH + 4` cycles.
- Adjacent windows in an output row have II=1. Row boundaries include virtual
  side padding and source-row capture pauses. Frames drain before the next begins.

All formulas are asserted in simulation rather than inferred from valid counts.
Backpressure increases wall-clock latency; pending synchronous-read data, padding
flags, raster markers and output payload hold together. Reset drops both cached
row and line-engine transactions by clearing controls; stale memory is suppressed
until new rows rebuild valid state. `marker_error` sticks for input framing errors.

The expanded regression tests VALID/ZERO/REPLICATE across ten configurations each,
including K=3/5, 1x1, widths below K, 8/10-bit and 32x24. Each configuration runs
three epochs with three complete frames per epoch, seeded backpressure and output
stall stability, reset of live held output, and malformed-marker diagnostics.
Payload, order, omitted transaction and SOF mutations must each fail the checker;
zero-output VALID cases correctly have no payload mutation target. Illegal static
parameters are separately rejected. `model.py` uses direct raster indexing,
independent of the bank/cache implementation. Runs snapshot their source files
and SHA-256 into fresh evidence directories. Old VALID evidence is retained.

Final expanded simulation evidence: `evidence/padding_sim_02/` contains all 30
passing configurations (270 complete input frames), 104 rejected mutations across
the 26 configurations producing output, and six rejected illegal parameter cases.
It includes immutable RTL/model/testbench snapshots, source hashes and logs.
`padding_sim_01` is retained as an earlier development run. The original VALID
core was not edited. Existing VALID synthesis evidence does not establish
padded-wrapper resource or timing acceptance; independent padding results follow.

## Padded-wrapper Gowin synthesis

```sh
python cores/signal_processing/dsp_isp_library/infra/window/synth_window.py
```

Twelve configurations passed real `synth_gowin -family gw2a -noalu` in
`evidence/padding_synth_20260925_023358_118551/`. This directory contains frozen
sources, source hashes, exact build scripts, logs, mapped JSON and resource JSON.
The following counts exclude IO pads and constants, and include the padding wrapper
plus its VALID engine. `MUX` is Gowin `MUX2_LUT5`, separately listed from LUT1–4.

| W×H | K | Bits | Padding | LUT1–4 | MUX | FF | BSRAM | DSP |
|---|---:|---:|---|---:|---:|---:|---:|---:|
| 32×24 | 3 | 8 | ZERO | 162 | 25 | 208 | 4 | 0 |
| 32×24 | 3 | 8 | REPLICATE | 167 | 33 | 207 | 4 | 0 |
| 32×24 | 3 | 10 | ZERO | 173 | 32 | 242 | 4 | 0 |
| 32×24 | 3 | 10 | REPLICATE | 173 | 34 | 241 | 4 | 0 |
| 32×24 | 5 | 8 | ZERO | 241 | 12 | 450 | 6 | 0 |
| 32×24 | 5 | 8 | REPLICATE | 236 | 10 | 449 | 6 | 0 |
| 32×24 | 5 | 10 | ZERO | 355 | 28 | 544 | 6 | 0 |
| 32×24 | 5 | 10 | REPLICATE | 361 | 37 | 543 | 6 | 0 |
| 1×1 | 3 | 10 | ZERO | 90 | 22 | 204 | 4 | 0 |
| 1×1 | 3 | 10 | REPLICATE | 89 | 23 | 203 | 4 | 0 |
| 1×1 | 5 | 10 | ZERO | 291 | 28 | 512 | 6 | 0 |
| 1×1 | 5 | 10 | REPLICATE | 288 | 22 | 511 | 6 | 0 |

All instances map to K `SPX9` primitives for the core banks plus one `DPX9B`
for the row cache, confirming synchronous-memory inference. The explicit RAM
hint retains BSRAM even for 1×1; tiny-image configurations are not optimized for
minimum block count. The horizontal `history` array intentionally maps to
registers (K*(K−1) samples); its Yosys memory-to-register warning is expected,
not a lost line RAM. The only other warning is ABC's combinational-network note.
No latch or width warning occurred; mapped JSON contains no latch cell.

These are synthesis counts, not placed packing, timing or physical acceptance.
No P&R, 27 MHz timing result, board programming or board capture was performed.
The board wrapper and any composed ISP algorithm add resources separately.
