# Stream morphology

Complete isolated erosion, dilation, opening and closing RTL with 3×3/5×5
programmable nonempty structuring elements, grayscale/binary modes, unsigned
8/10-bit pixels and ZERO/REPLICATE borders. See [SPEC.md](SPEC.md) for mask
reflection, finite-image boundaries, frame-atomic configuration and reset rules.
Simulation and representative synthesis pass; P&R and physical acceptance remain
pending. No board file, shared window RTL or CSC candidate was modified.

`morphology_stream` exposes the standard `s_`/`m_` Stream with SOF/EOL. Legal
configurations transfer atomically using `cfg_valid/cfg_ready` and pulse
`cfg_done`; empty masks pulse `cfg_error` and leave active fields intact.
While a frame is active, a held next configuration waits without stopping that
frame. The next frame cannot enter until the previous frame's final result is
accepted. `busy` spans that interval. This is essential for two-stage operations:
both stages always use the same frame's configuration.

One operation stage comprises shared `stream_window_padded` and `morph_reduce`.
The reduction uses a balanced 16-leaf or 32-leaf unsigned comparator tree (4/5
comparison levels), followed by one elastic register. Opening and closing pass
through two complete operation stages; erosion/dilation bypass the second stage.
Both stages physically remain available for runtime operation changes.

WIDTH is positive and at most the shared window's default 4096. HEIGHT is positive.
K, dimensions, pixel width and border mode are compile-time parameters. SOF/EOL
errors are sticky diagnostics, not automatic resynchronization. Input/output image
shape is unchanged. Reset clears control/valids and discards in-flight frames;
the underlying row banks are not cleared. There is no dynamic image-size update.

For `R=K/2`, the single-operation first-result latency without stalls is
`L = WIDTH*(1+min(R,HEIGHT-1)) + (K-1)*(WIDTH+K-1) + K-1 + 5` cycles from the
first accepted input. Opening/closing latency is `2*L` in the qualified matrix.
The audit checks all 384 no-stall frames, not only the first operation.
Examples: 7×6/K3 has 39/78 cycles; 9×8/K5 has 88/176 cycles for single/paired
operations. Output windows within each row have II=1, explicitly asserted for
all operations. Row capture/replay phases and full-frame drain reduce average
throughput; input ready propagates those pauses. Do not interpret row II as a
continuous full-frame pixel-rate guarantee. Backpressure stretches wall-clock
latency; the complete output tuple holds while stalled.

Model samples use direct two-dimensional neighborhood indexing, independent of
RTL's row caches and comparator tree. The operation is exact order comparison:
floating-point approximation, fixed-point rounding and saturation are inapplicable.
Binary conversion maps nonzero input to canonical numeric one, not full scale.
Asymmetric masks are explicitly tested; dilation reflects the erosion offsets.

## Reproduce

```sh
python cores/signal_processing/dsp_isp_library/isp/morphology/test_morphology.py
python cores/signal_processing/dsp_isp_library/isp/morphology/audit_latency.py <simulation-evidence-dir>
python cores/signal_processing/dsp_isp_library/isp/morphology/synth_morphology.py
```

Real simulation evidence: `evidence/sim_20260925_031412_017581/`.
Twelve configurations cover both border modes, 1×1, dimensions below K, K=3/5
and 8/10 bits. Each runs 32 configurations per epoch and three epochs: 1152
complete frames total, with every operation, binary/grayscale, full/center/cross/
asymmetric masks, zero/max/impulse/random images, held next-frame configs, random
producer gaps, seeded long/random sink stalls and in-flight reset with retained RAM.
Output data/order/count/sideband mutations are all rejected (48 negative runs).
Empty masks are rejected each epoch; five unsupported static parameters are
rejected separately. Markers, stable stalled output, config acknowledgment,
exact first-stage latency and row II are checked by the executable testbench.
Each run snapshots sources, shared dependencies, models and hashes.

## Isolated synthesis

Real `synth_gowin -family gw2a -noalu` evidence:
`evidence/synth_20260925_031500_464610/`. Complete runtime-selectable dual-stage
engine, WIDTH=32 and HEIGHT=24; core counts exclude IO pads and constants.

| K | Bits | Border | LUT1–4 | MUX2_LUT5 | FF | BSRAM | DSP |
|---|---:|---|---:|---:|---:|---:|---:|
| 3 | 8 | ZERO | 893 | 75 | 473 | 8 | 0 |
| 3 | 8 | REPLICATE | 881 | 84 | 471 | 8 | 0 |
| 5 | 10 | ZERO | 2513 | 149 | 1165 | 12 | 0 |
| 5 | 10 | REPLICATE | 2528 | 177 | 1163 | 12 | 0 |

BSRAM is `2*K` actual SPX9 banks plus two DPX9B row caches. No latch or width
warning occurred; horizontal-history conversion to registers is intentional.
ABC's combinational-network warning is expected during logic mapping.

These reports do not prove 27 MHz route timing or silicon behavior. The shared
inferred-memory implementation remains subject to the repository's active hardware
mapping investigation. Board wrapper, external-vector capture, repeat programming,
and production integration are still pending. No full-goal completion is claimed.
