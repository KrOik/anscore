# Same-frame adaptive RGB HDR tone compressor

`frame_adaptive_rgb_tonemap` captures a complete unsigned 16-bit linear RGB frame,
measures its max-channel brightness, derives an exposure pedestal and emits
RGB888 using one shared RGB denominator. Frame statistics, exposure and all
output pixels are calculated by RTL; no host histogram, tone LUT, intermediate
image or precomputed output is supplied. This is this package's independent
max-norm rational algorithm. It is not bit compatible with OpenCV or Reinhard.

Maturity: **LINT_PASS, UNIT_SIM_PASS (bounded scopes below), HW_UNVERIFIED**.
The original full 128脳128 playback exceeded the 20-second simulation deadline;
that test remains **TIMEOUT**, even though its late raw output contains a
completion marker and process exit 0. Maximum-size qualification covers full
capture/statistics and 64 checked output pixels followed by explicit abort.

## Arithmetic

Channels are unsigned integers 0..65535 with a common linear-light scale.
`s_rgb={R16,G16,B16}`; `m_rgb={R8,G8,B8}`. Let `N=WIDTH*HEIGHT`:

```
M[i] = max(R[i],G[i],B[i])
S = sum(M[i])
K = start_key_q8                       // unsigned Q4.8, integer 1..4095
A = max(1, floor((256*S + floor(N*K/2))/(N*K)))
D[i] = M[i] + A
out_C[i] = floor((255*C[i] + floor(D[i]/2))/D[i])
```

All divisions round to nearest with exact halves rounded upward. `A` is
rounded once before channel mapping; there is no hidden division of the mean
first. Increasing key reduces the pedestal and brightens the mapped frame.
Key 256 means 1.0. It is per-command exposure intent, not a measured sensor gain.
Using the same denominator for R/G/B preserves linear RGB ratios before final
8-bit rounding. Max-channel compression avoids per-channel highlight clipping;
it differs from luminance-weighted, log-average, local and gamma-encoded maps.
Output codes are compressed linear-light values; a display transfer/gamma
stage is a separate integration choice. No automatic white balance, demosaic,
HDR exposure merge, local adaptation or temporal exposure smoothing is included.

Bounds at supported dimensions:

| Quantity | Exact upper bound / interpretation |
| --- | --- |
| N |16384 |
| S |1073725440; fits 30 bits, stored in 32 bits |
| N*K |67092480; fits 26 bits |
| A |16776960; fits 24 bits |
| D |16842495; fits 25 bits |
| Rounded exposure dividend |274907258880; fits 39 bits, divider uses 40 bits |
| Rounded channel dividend |25132672; fits 25 bits |

`A>=1` makes every channel denominator nonzero. Since `C<=M`, channel output
stays within 0..255 without an overflow clamp. Black frames have `S=0,A=1`
and output 0. Constant full-scale white at key 256 maps to 128; at key 1 its
pedestal is 16776960 and output 1. The `(3,2,1),key 512` tie case gives `A=2`
and `(153,102,51)`. Quantization and the minimum pedestal can change exposure
invariance at very small input values; no exact scaling-invariance promise is
made after integer rounding.

## Parameters and ports

`WIDTH` and `HEIGHT` are independent elaboration parameters 1..128, defaults 32
and 24. `TAG_W` is 1..32, default 8. Invalid static parameters raise `$error`;
they are unsupported elaborations. Source lists are package-root relative.

| Ports | Contract |
| --- | --- |
| `clk,rst_n,ce` | One clock. Synchronous active-low reset overrides CE. CE freezes registers and RAM access. Reset flushes all pending work, output and DONE. RAM contents are not reset. |
| `start_valid/start_ready` | Accept a command only in IDLE. Snapshot `start_key_q8[11:0]` and `start_tag[TAG_W-1:0]`. Live values afterward have no effect. |
| `abort` | Sample only on enabled edges while active; idle and DONE ignore it. Masks input acceptance. A pre-existing output can transfer on the abort edge and is included in `done_count`. |
| `s_valid/s_ready,s_rgb[47:0]` | Accept pixels only during capture. Each fresh successful command overwrites all RAM positions before any replay. |
| `s_sof,s_eol,s_last` | Required respectively at pixel 0, every last column, and pixel N-1; exactly zero elsewhere. Missing pixels have no implicit timeout. |
| `m_valid/m_ready,m_rgb[23:0]` | Raster replay, one pixel at a time. Data/metadata remain stable under backpressure and CE pauses until transfer or accepted abort/reset. |
| `m_x,m_y[7:0]` | Zero-based output coordinates. |
| `m_sof,m_eol,m_last` | Exact output raster boundaries, meaningful with `m_valid`. |
| `m_tag,m_exposure[23:0]` | Latched command tag and computed pedestalA, same for the complete frame. |
| `done_valid/done_ready` | Held completion; no new command until acknowledged. Successful DONE follows acceptance of the final output. |
| `done_error[1:0]` |0 success ; 1 key 0 ; 2 invalid accepted input markers ; 3 abort. |
| `done_count[14:0]` | Number of output pixels transferred, including a simultaneous output/abort transfer. |
| `done_sum_max[31:0]` | Sum of correctly captured maxima; partial capture on error/abort. |
| `done_exposure[23:0],done_tag` | Computed pedestal or 0 before exposure finishes; original command tag. |

All handshakes require **`rst_n && ce && valid && ready` at the rising edge**.
Ready outputs are low with CE or reset low. Output valid and DONE remain
asserted while CE is low, so ordinary AXI-Stream endpoints require an explicit
CE adapter. A synchronous reset must span a clock edge. A held abort with
CE=0 does not cancel until an enabled edge. If an output is already valid and
ready on that edge, its transfer occurs before cancellation. After an aborted
replay, consumers must discard any prefix of that frame. A malformed capture
emits no pixels. Abort and reset can discard unconsumed output; DONE payload
holds without inspecting changing command/configuration inputs.

There is no external memory interface. Frame RAM is internal, packed 48 bits,
synchronous write/read and accessed by one active phase at a time. Addresses
advance only after accepted good capture pixels or accepted output pixels.
There is no simultaneous capture/replay, frame overlap or sensor buffering.

## Architecture and cycle budget

Capture updates one max-of-three and a 32-bit sum per accepted pixel. One 40-step
restoring unsigned divider, with 41-bit trial remainder, computes the exposure
and all three rounded channel quotients. `255*C` is a shift/subtract, and `N*K`
has constantN. There are no runtime general multipliers, LUT ROMs, floating
point operators, combinational `/` operators or vendor primitives.

For CE=1, continuous source and always-ready output: capture accepts II=1;
after the final input, exposure preparation/store take 42 enabled edges.
First output valid appears 170 enabled edges after the final capture;
first output transfers on edge 171. Subsequent output transfers are 129
enabled edges apart. Successful DONE asserts after `42+129*N` edges from
the final capture. From accepted start to successful DONE this is
`130*N+42` enabled edges. DONE acknowledgement and the next command require
separate subsequent edges. CE pauses, source gaps and backpressure add time;
unbounded stalls give no finite wall-clock deadline. These are RTL schedule
counts, not measured hardware frequency or a full-rate-video claim.

| Architecture risk | Assessment |
| --- | --- |
| Default RAM |32脳24脳48=36864 bits (4.5 KiB), no reset loop; MEDIUM mapping risk because 48-bit words may fragment BRAM. |
| Maximum RAM |128脳128脳48=786432 bits (96 KiB), **HIGH** target-device capacity risk. No external RAM is provided. |
| Arithmetic/control | One 40-bit iterative divider and add/compare/mux control, MEDIUM unmeasured critical-path risk; expected divider compare/subtract path. |
| Service rate | Sequential 129-cycle output service; suitability requires system cycle budgeting, not an assumed pixel-clock rate. |
| Hardware | No synthesis, PnR, STA, power or board measurement. Resource inference and actual clock frequency remain unverified. |

## Finite evidence and reproduction

Original receipt: `reports/20261105T180820675307Z/results.json`.
Default/example lint and four complete numeric/protocol profiles passed:

| W脳H / tag width | Independent source cases | Checked output pixels | Acknowledged DONE | Scope |
| --- | --- | --- | --- | --- |
|1脳1 /1 |14 |38 |51 | Extremes, rounding, full protocol |
|7脳5 /8 |14 |1330 |51 | RGB/random/gradient and full protocol |
|128脳1 /32 |8 |1024 |8 | Width/address and key/intensity boundaries |
|1脳128 /8 |8 |1024 |8 | Height/address and key/intensity boundaries |

The first two profiles each exercise three malformed final-sample markers,
key 0 rejection, CE-low reset in all 9 active FSM phases, held output/DONE,
abort in all 9 phases, simultaneous output+abort, reset while DONE, recovery
frames, busy-command rejection and CE/source/output pauses. The exact Python
Fraction oracle shares formulas but does not model divider bits or RTL FSMs.
Its additional 65536-code output-range invariant is an oracle check, not RTL
coverage of 65536 channel codes. Maturity does not claim exhaustive input or
parameter coverage.

Original max 128脳128 compile passed, but full playback is **TIMEOUT**. Its
26.5-second total includes the 20-second child deadline and bounded cleanup;
the taskkill helper itself timed out within 5 seconds, after which parent-kill
and pipe-drain fallback completed. A late PASS line/exit 0 does not qualify
that run. There was no RTL, original TB, runner or vector modification and no
full-playback retry after it.

Directed receipt: `reports/20261105T181323884558Z_max_prefix/results.json`.
It validates the original receipts/raw hashes and unchanged original inputs,
reuses saved vectors without regeneration, accepts all 16384 input pixels,
checks the computed same-frame sum/exposure and first 64 outputs, then verifies
abort count 64, held failed DONE and recovery. Both new children passed.
Overall accepted finite scopes compare 3480 output pixels in five passing
simulations. There are 13 PASS children and one retained TIMEOUT; no umbrella
PASS is asserted for the original full suite. Compile warnings concern only
unspecified production-module timescale; RTL contains no delays.

From repository root, the original bounded suite can be reproduced with:

```
python -B cores/image_processing/frame_adaptive_rgb_tonemap/run_tests.py
```

It includes the full maximum-size replay and can hit the 20-second deadline.
To reproduce only the saved-vector directed continuation:

```
python -B cores/image_processing/frame_adaptive_rgb_tonemap/run_max_prefix.py reports/20261105T180820675307Z
```

Both runners freeze exact executable inputs before preparation or any HDL
tool, record attempt and preparation-completion separately, preserve raw
stdout/stderr, tool/source/vector hashes and ordered planned checks, and stop
launching later checks after any failure/timeout. Each HDL child has a 20-second
watchdog plus bounded 7-second cleanup. Missing tools give NOT_RUN. PASS also
requires actual preparation, exact plan completion, immutable inputs and the
expected simulator completion marker. Saved evidence and production use need
no network or Python third-party package. Simulator images are temporary
`.build/` products and are not source dependencies.

Minimal complete wiring is `example/hdr32_example.sv`, top `hdr32_example`.
Compile from the package root with `-f example/files.f`; production uses
`-f files.f`. Both lists include all RTL and no testbench. Connect the
upstream linear RGB producer through the explicit start/capture handshake;
downstream sees compressed RGB888 plus raster markers. There is no implicit
direct wiring to the RAW Bayer HDR merge, which needs demosaic/color handling
and an explicit radiance-width/scale adapter.

Provenance and semantic deduplication: `SOURCES.md`, `references.json`.
Exact checked-to-delivered bridges and limitations: `B34_DELIVERY.json`.
