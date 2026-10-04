# ISP-08 basic ISP pipeline `basic_isp_top`

Streaming raster core composing four small, independently verifiable stages:

    input -> isp_blc -> isp_wb_gain -> isp_dpc -> isp_gamma -> output
                  \-> isp_awb_stats  (observer on the post-BLC bus)

Per input pixel, one output pixel in raster order (same-size stream,
`tuser` = SOF at (0,0), `tlast` = EOL at x = WIDTH-1).

## Data formats and geometry

`BITS` in {8, 10} unsigned per channel. `CH` in {1, 3}:

- `CH=1` gray / single plane: `s_tdata[BITS-1:0]`.
- `CH=3` packed `{R, G, B}` MSB->LSB (channel 0 = B in the LSB slice),
  matching `isp/csc_stream.v` channel order.

Image geometry is **static**: `WIDTH`/`HEIGHT` are module parameters.  This
is forced by the DPC stage, which builds on the fixed-geometry infra
`stream_window_padded` (3x3, REPLICATE).  The runtime config carries
`cfg_img_w`/`cfg_img_h` fields that must *equal* the static geometry —
anything else is rejected with `cfg_error`.  This catches driver
misprogramming while keeping the window foundation untouched.

Bayer-domain input is **out of scope**: correct DPC on Bayer needs a 5x5
same-phase neighbourhood, which this core does not implement (demosaic is
ISP-07 anyway).  `CH=1` mode is defined for gray/single-plane data.

## Integer contract (bit-exact, shared by RTL and `models/reference.py`)

Channel index `c`, pixel slice `p_c = tdata[c*BITS +: BITS]`, `MPX = 2^BITS-1`:

    blc_c  = (p_c >= off_c) ? p_c - off_c : 0              unsigned offset, clamp low
    wb_c   = min(MPX, (blc_c * gain_c + 128) >> 8)         gain UQ4.8, RNE + saturate
    nb_c   = the 8 neighbours of the centre tap (3x3 REPLICATE window)
    med8_c = (s[3] + s[4]) >> 1    s = sorted(nb_c)        floor mean of middle two
    defect = |wb_c - med8_c| > thr
    dpc_c  = defect ? med8_c : wb_c
    gamma  = sel==0 ? dpc_c : PWL(dpc_c)                   32 segments, 33 nodes

Pipeline order is BLC -> WB -> DPC -> gamma (as listed in the requirement);
each stage is a separate module with the same elastic handshake, so a
different composition is a wiring change, not a rewrite.

### DPC detection / replacement / cluster limit (defined)

- Detection: `|centre - med8| > thr` per channel, where `med8` is the floor
  mean of the 4th and 5th order statistics of the **8 neighbours**
  (centre excluded).  `thr = MPX` disables the stage entirely.
- Replacement: defective channel samples are replaced by `med8_c`; the other
  channels of the same pixel are untouched (per-channel independence).
- Cluster limit: with median-of-8, **up to 3 same-direction defective
  neighbours inside a 3x3 window cannot displace the two middle order
  statistics**, so isolated defects and <=3-neighbour clusters are always
  corrected exactly.  With >=4 like-polarity defective neighbours the median
  itself is polluted and correction is **not** guaranteed (example proven in
  `tests/test_models.py`: a 4-neighbour hot cluster yields med8 = 177 on a
  100-valued field).  This is the documented `坏点簇限制` bound.
- Defective neighbours still participate in the median (no neighbour
  pre-screening); border pixels are handled by REPLICATE padding.

### Gamma LUT (defined table source)

32 uniform segments over `[0, MPX]`, 33 nodes stored in the generated,
committed file `rtl/gamma_table.vh` (produced by
`models/reference.py::emit_gamma_vh`; `tests/test_models.py` fails if the
committed file is stale):

    node[i] = round_half_up(MPX * (x/MPX)^e),  x = min(i * 2^(BITS-5), MPX)
    idx  = v[BITS-1 -: 5];  frac = v[BITS-6:0];  STEP = 2^(BITS-5)
    out  = y0 + ((y1 - y0) * frac + STEP/2) >> (BITS-5)      round-half-up

`sel`: 0 = bypass, 1 = encode `e = 1/2.2`, 2 = decode `e = 2.2`, 3 = illegal
(`cfg_error`).  Accuracy vs the rounded real curve, measured exhaustively
(`test_models.py`): encode max |err| = 15 LSB (8-bit) / 60 LSB (10-bit),
concentrated at the black toe where `x^(1/2.2)` has unbounded slope;
decode max |err| = 2 LSB.  Node tables are monotone, `node[0]=0`,
`node[32]=MPX`.  Tables are combinational ROM (case functions): no RAM, no
clock-enable hazard — fully consistent with the GW2A robustness rule.

### External WB gain vs auto AWB (explicitly distinguished)

`isp_wb_gain` only *applies* externally supplied UQ4.8 gains.  Automatic
estimation is a defined two-part path, not a closed loop:

- **Statistics source (in RTL)**: `isp_awb_stats` observes the post-BLC /
  pre-WB bus and commits per-channel frame sums `awb_sum0/1/2` (SUMW =
  `clog2(FP*MPX+1)`, overflow impossible by construction), `awb_new` pulse
  and `awb_frame` (mod-256 completed-frame counter) at each frame's last
  accepted pixel.  Post-BLC linear data is the defined statistics point.
- **Estimator (host/model only)**: `models/reference.py::gray_world_gains`
  computes `gain_c = round_half_up(256 * mean_target / mean_c)`, `mean_target
  = mean of channel means`, clamped to [0, 4095]; a zero-mean channel yields
  neutral 256.  Gray-world accuracy: exact when the scene illuminant makes
  channel means equal; biased otherwise — a documented, simple algorithm as
  permitted by the requirement.  The host must commit the resulting gains
  through the normal atomic `cfg_wb` path; there is no in-hardware divide and
  no feedback claim.

## Stream, configuration, reset

Single `clk`, synchronous active-low `rst_n`.  Input `tdata/tvalid/tready` +
`tuser`(SOF) + `tlast`(EOL); output stream same contract.  `tvalid &&
!tready` holds data and markers at every stage boundary.

**Markers**: checked inside the DPC window core against the static geometry
on every accepted pixel (`tuser` == `(x==0 && y==0)`, `tlast` == `x==W-1`);
violations set sticky `marker_error` (until reset) and do not resync.

**Atomic config** (`cfg_valid`/`cfg_ready`): fields `cfg_img_w`, `cfg_img_h`,
`cfg_blc[3*BITS]` (LSB-first per channel), `cfg_wb[3*12]` (UQ4.8, LSB-first),
`cfg_dpc_thr[BITS]`, `cfg_gamma_sel[1:0]`.  `cfg_ready = rst_n && !busy`
asserts only while the whole pipeline is empty, so a commit can never land
inside a frame; a pending config defers the input by one cycle so the commit
edge never coincides with a take.  Legal updates pulse `cfg_done` and the
`cfg_commit` broadcast reaches all four stages in the same edge;
out-of-range fields (`img_* != geometry`, `gamma_sel == 3`) pulse `cfg_error`
and leave every stage's configuration intact.  Reset defaults: offsets 0,
gains 256 (1.0), `thr = MPX` (DPC off), `sel = 0` (gamma bypass).

`busy = fopen || outstanding != 0`, where `outstanding` counts accepted-but-
not-emitted pixels; it covers mid-frame input gaps and the window's drain
tail.

## Latency / throughput

- `isp_blc`, `isp_wb_gain`, `isp_gamma`: II=1, 1-cycle latency each.
- `isp_dpc`: `stream_window_padded` alternates CAPTURE/REPLAY, so *input*
  accept is bursty (`s_tready` only while capturing a row); the output
  still emits exactly one beat per pixel.  Sustained input rate is
  `WIDTH/(WIDTH+2)` pixels/cycle; first output appears after the first two
  input rows are in.  This is inherited from the infra window, same as the
  delivered median/convolution cores.
- AWB sums commit one cycle after a frame's last accepted pixel.

## GW2A robustness

No CE-gated RAM reads anywhere: the DPC row buffers use the infra window's
`ram_style="registers"` fabric storage (the fixed version, which the recent
regressions confirmed); gamma node tables are combinational ROM; WB/BLC are
pure datapath.  Nothing holds data in a RAM output across a stall.

## Resource summary (isolated `synth_gowin -noalu -family gw2a`)

| config | LUT1-4 | FF | DSP | BRAM |
|---|---|---|---|---|
| top 8b c3 32x24 | 5789 | 4157 | 3 | 0 |
| top 10b c3 32x24 | 6736 | 5107 | 6 | 0 |
| top 10b c3 64x64 | 10379 | 9005 | 6 | 0 |
| top 10b c1 64x64 | 3571 | 3141 | 2 | 0 |
| top 8b c1 8x8 | 1258 | 683 | 1 | 0 |
| isp_blc (8b c3) | 55 | 51 | 0 | 0 |
| isp_wb_gain (8b c3) | 161 | 63 | 3 | 0 |
| isp_gamma (8b c3) | 398 | 29 | 0 | 0 |
| isp_awb_stats (8b c3 32x24) | 133 | 127 | 0 | 0 |
| isp_dpc (8b c3 32x24) | 4826 | 3816 | 0 | 0 |

DSP usage is the WB per-channel multipliers (CH of them) plus the gamma
per-channel interpolators at 10-bit (CH more); the DPC median network is
LUT-only.  See `evidence/synth_*/summary.json`.

## Limits

- Static geometry only (window foundation constraint); runtime `img_*`
  fields exist purely as a legality check.
- Bayer-domain DPC/BLC/WB out of scope (needs 5x5 same-phase window);
  `CH=1` is gray/single-plane.
- Input accept is bursty inside DPC (CAPTURE/REPLAY), so end-to-end input
  II is not 1 — the *output* is exactly one beat per input pixel.
- Gray-world AWB estimate is a host-side model suggestion; applying it still
  goes through the external WB config path.  No closed loop is claimed.
- Defect clusters with >=4 same-direction defective neighbours may be
  under-corrected (defined bound above).
- Gamma PWL toe error documented above; a finer/denser table is a drop-in
  `.vh` regeneration, not an RTL change.
- No P&R, routed timing or board claim yet.
