# Local RAW green-phase equalization

Original Apache-2.0 `raw_green_equalize` suppresses small, locally consistent
Gr/Gb differences before demosaic. It uses original cross-green diagonal
samples, gates correction by local texture and phase difference, and preserves
R/B and the complete one-pixel frame boundary. The actual `green_bayer_rgb`
composition connects RAW10 through this core and the unchanged legacy Bayer
engine. Baseline: `1e9e9130cef71127d2c8d2762affe815b067b9f5`.

This is a spatial local correction. Existing RAW white balance already computes
separate full-frame/ROI gains for Gr and Gb toward a pooled green target. That
global estimator is unchanged. Existing RAW DPC and defect-map repair use
same-exact-phase donors for large defects; they do not blend the two green
phases under this local small-difference rule. Existing bilinear/MHC demosaic,
tone mapping, temporal denoise, deinterlacing and sprite packages are unchanged.

## Exact integer rule

Parameters: WIDTH/HEIGHT1..512, WIDTH*HEIGHT<=65536, BITS8/10/12, TAG_W1..32.
Defaults64x48, RAW12, TAG8. Inputs and outputs are unsigned linear RAW integers.
The pattern at the first pixel uses canonical ABI0 RGGB,1 GRBG,2 GBRG,3 BGGR.
At `(x,y)`, `site={y[0],x[0]} XOR pattern`:0 R,1 Gr,2 Gb,3 B. Pattern describes
the post-ROI phase; no hidden sensor-origin offset is applied.

For an interior green center C, let TL,TR,BL,BR be the four original diagonal
samples, all of the other green phase. Define:

```
S = TL + TR + BL + BR
D = floor((S + 2) / 4)
range = max(TL,TR,BL,BR) - min(TL,TR,BL,BR)
apply = enable && interior_green && range <= edge_threshold
        && abs(C-D) <= imbalance_threshold
output = apply ? floor((4*C + S + 4) / 8) : C
```

Both thresholds include equality. An applied predicate may produce no numeric
change: `m_applied` is that predicate; `m_changed` means output differs from C.
Disable uses the latched enable bit. Threshold0 still permits exact equality.
The diagonal average is rounded only for the gate; the output directly uses
the original full S and rounds once. No repaired value feeds another pixel.
For flat interior Gr=a/Gb=b, both green phases reach `(a+b+1)>>1` if admitted.
R/B, any outer boundary, and all pixels in width/height1 or2 pass unchanged.
Replicated window-edge samples are never used to correct a boundary green.

S and S+2 fit BITS+2. Absolute differences/range fit BITS. The mixture plus bias
is at most `8*(2^BITS-1)+4 < 2^(BITS+3)`; convex rounding keeps output in range.
No saturation, multiplication or division operator is required. This simple
texture gate can still smooth fine green detail; no sensor calibration,
RawTherapee equivalence or photographic-quality guarantee is claimed.

## Interface, ownership and errors

All public transfers are ordinary `valid && ready` on one clock. Reset is
synchronous active-high, overrides operation, masks public ready/valid/busy,
and cancels the complete epoch without DONE. No CE or CDC is present. The two
unchanged window dependencies use synchronous active-low reset; the core
explicitly converts polarity and locally resets their control between commands.
Array payloads are not reset. The next frame overwrites required rows before
they can contribute to a visible window.

START `c_valid/c_ready` snapshots enable, pattern, both thresholds and tag.
Exactly WIDTH*HEIGHT input tokens follow in raster order. SOF is true only on
the first token, EOL on each final column, LAST only on the final token. The
source may pause and must hold offered data/markers while blocked. Configuration
pins may change after START without affecting the owned frame.

The core validates all three input markers, but continues consuming the fixed
N tokens and regenerates canonical markers for the window. A malformed frame
can therefore have emitted a prefix or its whole output before error DONE;
the consumer must discard that frame. There is no marker-based resynchronizer,
partial rollback, runtime abort or implicit watchdog. A missing source or
unbounded backpressure can stall forever; reset is cancellation.

Output preserves full geometry and order. Pixel, applied/changed flags and
SOF/EOL/LAST hold together under backpressure. Two elastic arithmetic stages
follow the window and can each hold a token. The source-derived arithmetic
burst initiation interval is1; this does not make the row-capture/replay
foundation a continuous one-input-per-clock camera pipeline.

Held DONE appears only after final output acceptance, returning the original
tag, two error bits and17-bit counts of accepted applied/changed output pixels.
Error bit0 means malformed caller SOF/EOL/LAST; bit1 means unexpected internal
window marker/alignment error. Counters include65536 without wrapping. DONE
payload remains stable until accepted. START is blocked through active capture,
window processing, output holds and held DONE. No next frame is speculatively
admitted.

## Actual RAW10 to RGB composition

`example/green_bayer_rgb.sv` instantiates this new core and unchanged
`dsp_isp_library/isp/bayer/rtl/bayer_demosaic.sv`. The old Bayer core supports
RAW8/10 only; the example is explicitly limited to8/10, default10. The GIC core
independently supports RAW12. Both stages use the unchanged
`stream_window_padded.v` and `stream_window.v`; there are two actual window
instances, not a claim of shared physical rows.

The wrapper maps canonical pattern0/1/2/3 to old Bayer0/2/3/1 and sets origin
parities to0. The old bilinear kernel retains truncating averages and replicated
edges. RGB is packed `{R,G,B}`, each channel BITS wide. Input errors remain in
public DONE. Public error bit2 is the old Bayer marker/configuration error.
The wrapper admits configuration atomically into both children, saves GIC DONE
counts, and retains ownership until the final RGB pixel is accepted. A held
last RGB cannot be bypassed by either GIC DONE or a future START. Public DONE
then holds tag/error/counts until accepted. All peers share reset.

## Architecture budget and finite plan

New controller/arithmetic state is a few hundred bits and has no pixel array,
DSP, multiplier, divider, vendor primitive or external-memory dependency.
The legacy window intentionally specifies `ram_style="registers"` for its
capture row and three line banks; this package does not relabel them as BRAM.
Declared row arrays per window contain `(WIDTH+3*(WIDTH+2))*BITS` bits:
default64/RAW12 =3144, maximum512/RAW12 =24648. History, read/output registers,
coordinates and new control are additional. Default resource risk LOW/MEDIUM;
maximum HIGH. Physical packing, Fmax and device fit are unmeasured.

The actual default16x12/RAW10 composition has two700-bit row-array sets, total
1400 declared row bits. Maximum legal512x128/RAW10 has two20540-bit sets, total
41080, plus both window histories/pipelines, Bayer and GIC control. Maximum
composition risk HIGH. No RAM pruning or synthesis result is assumed.

Per complete frame, the row foundation requires N capture transfers and
`(HEIGHT+2)*(WIDTH+2)` padded replay issues, plus control/pipeline drain and
external waits. Capture/replay phases alternate, so a window-output II1 burst
is distinct from whole-frame sustained service. The actual chain includes
both foundations and downstream contention. No hardware FPS or Fmax is claimed.

PRECHECK_PLAN defines11 finite children: default/maximum/example syntax checks,
three core compile/simulation pairs and one actual composition pair. Core
profiles are1x1/RAW8/TAG1,9x7/RAW10/TAG8 and32x24/RAW12/TAG32; maximum512x128 is
syntax-only. Each simulation will check16 independently modeled scenes twice,
including all patterns, equality/adjacent rejected thresholds, disable, full
scale, spatial texture, malformed markers, stalls, held final pixels/DONE,
future START blocking, reset after first input, held first output, held DONE,
and complete recovery. The actual chain will compare full16x12 RGB rasters.

All12 executable inputs, including this plan and three unchanged dependencies,
must be archived before oracle import. All20 vector files must be generated
once and frozen before the first HDL child. Durable INCOMPLETE checkpoints
precede oracle import/preparation and follow every child. Existing started
report directories, including empty ones, block another attempt. Each child
has20s execution and bounded7s cleanup; first failure stops later launches.
There is no automatic repair or retry. No synthesis/PnR/STA/board, PPA search,
old regression, maximum frame simulation or external reference execution.

## B39 finite evidence and retained failure

Qualification is LINT_PASS / UNIT_SIM_PASS / INTEGRATION_CANDIDATE /
HW_UNVERIFIED, using two explicitly reviewed execution segments. This is not a
first-attempt full-suite pass. The first run passed six children, including
the1x1 simulation, then stopped at the9x7 TB watchdog. The cancellation scene
held all outputs while synchronously waiting to feed a complete frame; the
row-capture/replay window propagated backpressure before that task could reach
its reset. No pixel mismatch was reported. The original FAIL receipt, all exact
inputs/vectors/raw streams and failed image are retained unchanged.

Root authorized one minimal TB-only correction after source diagnosis and a
new complete cross-review. The cancellation-only driver now offers original
prefix tokens only on already-ready capture cycles, stops on first output
valid without withdrawing a blocked offer, holds that output three clocks,
then resets. No production RTL, oracle, original plan, original runner, vector,
numeric expectation or watchdog changed. Three passed syntax checks and the
passed1x1 profile were not rerun.

The separate six-child repair plan passed all six children and three simulations
once, with no new preparation or oracle import, failure, timeout or cleanup.
It recompiled/retested9x7 and first ran RAW12 and the actual RAW10 RGB chain,
reusing the original20 frozen vector files. Primary receipt:
`repair_reports/20261106T055649817455Z/results.json`, SHA256
`a8b72d4c88976cb95ee8323de19ac511abac237ad41a7fa6bca95daa6abf6b55`.
Original FAIL receipt: `reports/20261106T054813653406Z/results.json`, SHA256
`af576777ddd66840850017de702964733bc0740b078b628e69aa66697fc561da`.

Across both segments there were13 HDL child executions,12 PASS and one retained
FAIL; five simulation executions yielded four successful simulations and one
historical watchdog failure. The original11 distinct planned checks are covered
by successful segments, with the9x7 compile occurring twice. Source archives
record both TB versions; the1x1 result applies to its original exact TB, while
all three later successful simulations use the corrected TB. Both production
RTL modules remained byte-identical throughout.

Four successful simulations checked32768 output records:26624 RAW pixel/flag
records and6144 RGB pixels. The actual chain checked32 complete16x12 rasters,
including two intentionally marker-invalid input frames reported bad at DONE.
Totals are136 accepted commands,128 checked DONE records and16 resets (four
initial,12 live). Eight commands reset before complete output; four additional
checked DONE responses reset while held before retirement. Successful-run
counts are7512 applied and6260 changed pixels; held output cycles total8456.
All four successful simulations reached `$finish` and had empty stderr.
Compile notices concern missing time units/precision only in unchanged window
and Bayer dependencies. Maximum geometry remains syntax-only; hardware
packing, device fit, Fmax and sustained camera throughput remain unmeasured.

`QUALIFICATION.json` and `B39_DELIVERY.json` enumerate primary/prior evidence,
hashes and exact counts. `FAILURE_ARCHIVE.json` identifies the failed image for
permanent retention; it is explicitly excluded from successful-temp cleanup.

## Official reference, read only

Actual RawTherapee `rtengine/green_equil_RT.cc` and LICENSE were retrieved at
pin `b2ee504c47e5e6d5e054395aa12bf1fe43bd1c3c`. Its GPLv3-or-later source uses
global green means and a larger local neighborhood with directional floating
weights/texture screening. It establishes the application and useful boundary
questions, not the arithmetic of this independent integer3x3 rule. No upstream
code is imported, translated, executed or required offline. URLs and full-file
SHA256 values are recorded in references.json.
