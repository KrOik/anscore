# Pipelined 3x3 / 5x5 median

Status: isolated RTL, independent model, real Icarus simulation and Gowin noalu
synthesis PASS. No P&R, board qualification or production acceptance is claimed.
Only this directory was changed; shared window implementation is referenced
read-only and copied into evidence snapshots.

`median_stream` accepts unsigned8/10-bit image pixels with ready/valid and
pixel-bound SOF/EOL. WIDTH/HEIGHT are positive compile-time dimensions,
K=3/5, PAD_MODE=0 ZERO or1 REPLICATE; output preserves WIDTHxHEIGHT geometry.
MAX_WIDTH defaults4096 and is enforced by the shared padded window. There is
no dynamic configuration or mixed-frame configuration update. Unsupported
static settings fail simulation/elaboration rather than run silently.

The center order statistic is sorted rank4 of9 or rank12 of25. ZERO padding
participates in sorting as zeros, including borders of tiny images; replicated
padding clamps both coordinates. Samples remain unsigned with no scaling,
rounding or saturation. Equal samples may exchange positions inside the network
but the median value is unambiguous; no stable identity among equal taps is
promised. `model.py` independently indexes each image neighborhood and uses
integer sorting, plus a floating-point statistics.median reference. Outputs
match exactly for the supported8/10-bit integer values.

Architecture:

```
pixel Stream -> shared stream_window_padded -> median_network -> pixel Stream
               synchronous row RAM + K-bank     registered compare-exchange
               window, ZERO/REPLICATE            at every bitonic level
```

The old imgwin median3x3 was inspected:8-bit, combinational21 compare-swaps,
approximately9 compare levels, asynchronous reset/clk_en, and no ready/valid.
It remains unchanged. The new common3/5 implementation uses a regular bitonic
network to register every comparison level and support both widths under the
tested Stream contract. Padding unused sorting lanes with maximum values makes
the selected median rank unchanged, including real maximum-valued pixels.

| K | Sorting lanes | Logical comparator count | Registered levels / sort latency | Sorter II |
|---|---:|---:|---:|---:|
| 3 | 16 (9 data +7 maximum sentinels) | 80 | 10 | 1 |
| 5 | 32 (25 data +7 maximum sentinels) | 240 | 15 | 1 |

Counts describe the generated full network; synthesis removes constant and
unused-result logic. Each comparison level has its own payload registers.
All levels advance together when final output is empty or accepted; blocked
valid output freezes data, valid, SOF and EOL and deasserts input ready. Arithmetic
registers update only for their valid beat. Reset is synchronous active-low,
clears valid/control/error and discards all in-flight pixels; large RAM and
invalid payload registers are not reset. Rebuilt window state prevents stale
memory from becoming valid. Marker_error is the shared sticky raster diagnostic;
malformed markers do not silently change configured dimensions.

The sorting network is II1, but the padded row-cache accepts a row then replays
it and cannot stream a whole frame at input II1. During output rows the complete
chain emits consecutive pixels at II1. Let R=K/2, PW=WIDTH+K-1,
PH=HEIGHT+K-1, L=10 or15. Without source/sink stalls, measured/ asserted:

- First accepted pixel to first output transfer:
  `WIDTH*(1+min(R,HEIGHT-1))+(K-1)*PW+K-1+4+L` clocks.
- Last accepted input to last output transfer:
  `PW*(HEIGHT==1 ? K : R+1)+4+L` clocks.
- Consecutive frame-start input acceptance interval:
  `WIDTH*HEIGHT+PW*PH+4` clocks.

No dummy external tail pixels are required. Median tail from an earlier frame
may drain while the shared window captures the next frame; order/markers stay
aligned. Under backpressure these are effective-progress relationships, not
bounded wall-clock latency. Ready is combinational through the sorter/window;
use shared synchronous FIFO where a long ready chain must be broken.

Reproduce from repository root:

```
python cores/signal_processing/dsp_isp_library/isp/median/test_median.py
python cores/signal_processing/dsp_isp_library/isp/median/audit_timing.py
python cores/signal_processing/dsp_isp_library/isp/median/synth_median.py
```

Simulation `evidence/sim_20260925_033407_661717/`:24 configurations across
1x1,2x3,7x6; both K/bit widths/borders; six deterministic zero/maximum/impulse/
checkerboard/random frames in each of three reset epochs (432 complete frames).
Includes randomized source/sink, prolonged stalls, valid held across pauses,
reset of live held output with stale RAM retained, malformed-marker error,
five illegal-parameter rejections and92 rejected checker mutations. Order
mutation is explicitly inapplicable to1x1 ZERO cases because all output values
and markers are identical; data/sideband/count corruption is still rejected.
`evidence/timing_20260925_033759_288873/` rechecks all24 configurations with
explicit first/tail/frame interval and output-row II assertions.

Synthesis `evidence/synth_20260925_033703_241459/` contains source hashes,
exact scripts, logs, mapped JSON and per-case cell counts. All12 isolated/core
and complete-wrapper configurations pass -family gw2a -noalu; no latch cells.
LUT counts below sum Gowin LUT1..4; MUX counts remain separately in JSON.

| Scope | K / Bits | LUT | FF | BSRAM | DSP |
|---|---|---:|---:|---:|---:|
| Sorter only | 3 /8 | 1198 | 806 | 0 | 0 |
| Sorter only | 3 /10 | 1580 | 1000 | 0 | 0 |
| Sorter only | 5 /8 | 4379 | 2741 | 0 | 0 |
| Sorter only | 5 /10 | 5737 | 3415 | 0 | 0 |
| 32x24 window+sort, ZERO | 3 /8 | 1343 | 1014 | 4 | 0 |
| 32x24 window+sort, REPLICATE | 3 /8 | 1353 | 1013 | 4 | 0 |
| 32x24 window+sort, ZERO | 3 /10 | 1774 | 1242 | 4 | 0 |
| 32x24 window+sort, REPLICATE | 3 /10 | 1757 | 1241 | 4 | 0 |
| 32x24 window+sort, ZERO | 5 /8 | 4558 | 3191 | 6 | 0 |
| 32x24 window+sort, REPLICATE | 5 /8 | 4553 | 3190 | 6 | 0 |
| 32x24 window+sort, ZERO | 5 /10 | 6104 | 3959 | 6 | 0 |
| 32x24 window+sort, REPLICATE | 5 /10 | 6092 | 3958 | 6 | 0 |

Resource gates pass in synthesis, but27MHz route timing and physical image
acceptance remain unverified. Shared RAM inference, board input/output and
representative full-image boundary qualification require their own evidence.
