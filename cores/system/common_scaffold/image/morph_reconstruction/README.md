# Grayscale morphological reconstruction

`morph_reconstruct_frame` performs full-frame grayscale reconstruction by
dilation or erosion under a mask, with runtime 4/8 connectivity and an explicit
iteration limit. This is grayscale geodesic reconstruction, distinct from
ordinary dilation/erosion or binary hole filling. Static BITS is 8–12;
WIDTH/HEIGHT are 1–4096. Input pixels retain their full unsigned precision.

## Exact simultaneous update

Each accepted input pair supplies a marker image F0[p] and mask M[p]. The
neighborhood contains the current pixel itself and all in-bounds neighbors:
four cardinal neighbors for connect8=0; all eight surrounding neighbors for
connect8=1. Outside-frame neighbors are excluded, with no padding or wrapping.

```
dilation: F(t+1)[p] = min(M[p], max(F(t)[q] for q in neighborhood(p)))
erosion:  F(t+1)[p] = max(M[p], min(F(t)[q] for q in neighborhood(p)))
```

Every pixel of iteration t+1 reads only the completed iteration t. Two
synchronous state RAM banks alternate after the last pixel, so raster position
does not introduce in-place propagation. Mask storage is immutable during
processing. Dilation requires marker<=mask at every pixel; erosion requires
marker>=mask. Any violation latches constraint_error. The core consumes the
entire fixed-length input frame, performs zero iterations and outputs the
**original unmodified marker image** as a diagnostic candidate. It does not
silently clip an illegal marker to its mask. The consumer must discard this
candidate as a reconstruction result.

## Configuration and convergence status

cfg_erosion, cfg_connect8 and cfg_max_iterations are sampled only on the first
accepted pair. Changes after that transfer have no effect on capture validation
or computation. cfg_max_iterations is unsigned16 and must be 1–65535. Zero
latches config_error and outputs the original marker with zero iterations.
Configuration signals do not gate progress of an active frame.

After each complete update the core compares every new pixel with its old
pixel. If all are equal, converged is asserted and processing stops. This
unchanged confirmation iteration **counts in iterations_done**: an already
stable/constant/single-pixel input takes one iteration, not zero. If the last
allowed update changed anything, limit_reached is asserted, converged remains
false and the newest complete candidate image is output. That candidate may
already equal the fixed point, but the core has not observed a subsequent
unchanged update and does not claim convergence. Equality wins over a limit
reached on the same iteration. Legal convergence has limit_reached=0.

For legal pairs, finite-grid reconstruction is monotone: dilation never
decreases or exceeds mask; erosion never increases or falls below mask. A
simple path has at most W*H-1 edges, so W*H complete updates suffice to include
the fixed point and its unchanged confirmation. This is an algorithmic bound,
not an automatic extension of the configured limit. Large geometries can
require more than the16-bit limit; callers must inspect converged/limit_reached.

## Streaming and error recovery

One s_valid/s_ready handshake captures both s_marker and s_mask, preserving
their exact pixel correspondence. Every transfer requires ce && valid && ready.
The first pair must carry SOF, and the last pair in each row EOL; no others may
carry those flags. Incorrect framing sets marker_error while computation and
the complete output continue. The consumer must discard the entire frame on
framing errors, even if converged is true. constraint_error concerns intensity
ordering, whereas marker_error concerns SOF/EOL framing.

The fixed frame length is WIDTH*HEIGHT. A missing pair cannot be inferred from
markers: supply the remaining transfers or reset. Input is stalled throughout
iteration, output and held DONE. Output raster coordinates, SOF/EOL/LAST,
candidate pixels and all status flags remain stable during output backpressure
and CE pauses. DONE and final status remain held until done_ready. A next
frame's first accepted pair clears previous status and snapshots configuration.
busy covers partial capture and all later processing states.

Synchronous active-high reset overrides CE and cancels pending capture,
iterations or output. RAM arrays are not reset. Capture initializes marker
bank0 and mask before any read; a whole new state bank is written before each
bank switch. Thus scratch contents from a previous frame/reset are never used
as current coefficients. No asynchronous state RAM reads are present.

## Architecture and bounds

Three RAMs hold marker/current state A, scratch state B and mask, totaling
3*WIDTH*HEIGHT*BITS bits. A serial neighborhood scan reuses one unsigned
min/max comparator; writes go to the inactive bank. There are no multipliers,
DSPs, host-computed pixels or placeholder flow stages. This is frame-buffered,
multi-cycle processing. Each update costs O(W*H*neighborhood_size) enabled
cycles, and output is separately backpressured. No video-rate throughput claim
is made. Legal maximum geometries may exceed the target FPGA's RAM budget.

Pixel operations select/clamp existing BITS values, so no arithmetic overflow
or quantization occurs. Coordinates use bounded integer neighbors (-1 through
WIDTH/HEIGHT); frame addresses cover WIDTH*HEIGHT. The16-bit update counter
stops at or before the configured 65535, preventing rollover. Bank switching
and changed detection occur after the last write, including changes at that
last pixel.

## Validation

```
python -B cores/system/common_scaffold/image/morph_reconstruction/test_morph_reconstruct.py
python -B cores/system/common_scaffold/image/morph_reconstruction/synth_morph_reconstruct.py
```

NumPy/scikit-image are required by the regression. Six profiles/150 frames/
2675 pixels PASS against an independent Python simultaneous-update oracle,
including exact iteration counts and all output/terminal flags. Actual
scikit-image0.25.2 reconstruction matches122 converged valid frames. Ten
limited cases compare the exact intermediate candidate and monotone bound
against the full reference; six invalid-limit frames preserve their marker.
Twelve illegal marker/mask frames are also rejected by actual scikit-image.

Cases cover dilation/erosion, both neighborhoods, black/full/equal inputs,
single pixels/rows/columns, obstacles, serpentine channels, multiple seeds,
diagonal-only connectivity, arbitrary random legal pairs for every op/connectivity
combination, first-pixel configuration snapshot, unchanged first iteration,
one-iteration limits, zero-limit errors, violations at first/last input,
SOF/EOL faults and next-frame recovery. The longest fixture takes24 iterations.
CE/input gaps/backpressure, held DONE, and CE-low reset during capture, active
iteration and stalled output are tested. Four illegal static configurations
are rejected. All generated hex/binaries/testbenches are temporary.

Isolated synth_gowin and CHECK PASS:

| Profile | LUT1–4 | LUT5 mux | ALU | FF | RAM primitives | DSP |
|---|---:|---:|---:|---:|---|---:|
| B8,32x32 | 307 | 41 | 123 | 161 | 3 DPX9B | 0 |
| B12,64x48 | 374 | 49 | 175 | 200 | 9 DPB | 0 |

No timing closure, integrated budget, board or application acceptance is claimed.
Only small evidence JSON files are retained; temporary build products are removed.

## Public mathematical reference

Successfully accessed 2026-10-19:
https://raw.githubusercontent.com/scikit-image/scikit-image/v0.24.0/skimage/morphology/grayreconstruct.py
Its reconstruction documentation states seed-under-mask dilation, the dual
erosion relation, and neighborhood/footprint control. No implementation code
was copied. Actual-package comparisons use an explicit3x3 cross or full3x3
footprint with center included, method dilation/erosion, integer marker/mask.
scikit-image's algorithm and iteration schedule differ internally; only final
fixed-point images are equated. Our intermediate images and iteration counts
follow the simultaneous contract above, not an external library's schedule.
