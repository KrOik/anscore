# Adaptive directional RAW defect repair

Original Apache-2.0 RAW hot/dead-pixel repair with a local envelope detector,
gradient-adaptive threshold and four-direction predictor. It reads eight
**original** samples at the same exact Bayer phase, two pixels from the center.
Status: AUTHORED / EXECUTION_PENDING / HW_UNVERIFIED. The frozen finite plan
requires separate root and peer approval before any project/model/HDL execution.

## Exact numerical contract

WIDTH/HEIGHT are 1..512 with product <=65536; BITS is 8,10,12; TAG_W is 1..32.
The core is independent of the CFA naming convention because all donor offsets
have even x and y. The complete two-pixel outer border passes unchanged, so
frames narrower or shorter than five pixels pass unchanged.

For each eligible interior pixel C, the four opposing pairs in priority order
are H=(W,E), V=(N,S), backslash=(NW,SE), slash=(NE,SW), at radius two. Let:

```
g[d] = abs(pair[d][0] - pair[d][1])
d*   = first direction with minimum g[d]
P    = floor((pair[d*][0] + pair[d*][1] + 1) / 2)
L,U  = minimum,maximum of all eight donors
E    = max(L-C, C-U, 0)
T    = base_threshold + (g[d*] >> gradient_shift)
repair = enable && interior && E > T
output = repair ? P : C
```

`gradient_shift` is 0..3. T is an **unsaturated BITS+1** integer, up to
2*(2^BITS-1). Equality E=T passes unchanged. Pair interpolation rounds half-up
once in BITS+1 bits. A repaired result lies inside [L,U], and therefore differs
from the outlying center. `m_repaired` identifies replacement; `m_direction` is
the selected 0/1/2/3 direction on repair and zero otherwise. Original donor
values are never overwritten or fed back. No sorting, data multiplication,
division, CFA cross-phase averaging, static defect map or gain correction is used.

The envelope rule preserves every center already within its donor range, even
when it is distant from their median. A real isolated highlight/thin feature
outside that range can still be rejected. A bad donor can hide a defect or
mislead direction selection. There is no calibrated cluster-repair, sensor
noise-model, photographic-quality or vendor-equivalence guarantee.

## Frame ownership and errors

One clock, ordinary rising-edge ready/valid, synchronous active-high reset.
START captures enable, base, shift and tag. It owns exactly WIDTH*HEIGHT input
and output transfers through held DONE. Live configuration changes after START
have no effect. START cannot fall through on the same edge as DONE retirement.
Reset masks ready/valid/busy, cancels the unretired epoch, and emits no DONE.
RAM payloads are not reset; the next owned frame refreshes required history.

Input SOF is true only on the first token, EOL at each last column, LAST only
on the final token. A mismatch sets d_error[0], but capture continues for the
fixed N samples. Canonical markers feed the window. The output can contain a
prefix or an entire numerically corrected raster before error DONE; the caller
must discard the entire error epoch. d_error[1] reports a window invariant or
window marker fault. Output data/flags/markers and DONE fields hold under stalls.
DONE includes the captured tag and unsigned17 count of retired repairs.

## Actual RAW-to-RGB composition

`example/directional_bayer_rgb.sv` instantiates this core followed by the unchanged
production `bayer_demosaic`, including its real K3 row windows and floor-rounded
bilinear RGB reconstruction. It supports RAW8/10. Public pattern0 RGGB,1 GRBG,
2 GBRG,3 BGGR is explicitly mapped to the older engine's 0,2,3,1 ABI at START.
The adapter owns both completions and waits for the last RGB output to retire;
RAW completion alone does not release the next command. d_error[1:0] comes from
repair and d_error[2] reports Bayer configuration/window errors. Every input and
output stream remains ordinary ready/valid; there is no hidden CE connection.

## Architecture and finite evidence boundary

The existing K5 padded row-window engine is reused without edits. Three local
elastic stages compute donor sums/extrema/differences, choose the predictor,
then apply the adaptive detector. Local accepted-window II=1; row capture/replay
gaps remain part of complete service. Source gaps and output/DONE stalls are
unbounded, so neither fixed camera bandwidth nor a worst wall-clock time is
promised. See ARCHITECTURE.md for storage and arithmetic bounds.

The proposed suite has eight direct preparations, two syntax children and eight
compile/simulation pairs:26 children total,18 HDL children,8 retained VVP images.
Profiles cover 1x1,2x4,5x5,7x7,1x512,256x256 and the real 7x7/512x1 Bayer chain.
The independent integer oracle generates fresh vectors before any HDL child.
Tests compare every output/flag/marker and repair summary, exercise all four
directions/ties, strict thresholds, half-up averages, threshold overflow,
all shifts, disable, borders, four CFAs, source gaps, held first/last output,
held DONE, changing inactive config pins, three marker errors, and reset after
an admitted input/with output held/with DONE held followed by fresh epochs.

No project execution has occurred at source authoring. No synthesis, PnR, STA,
board, PPA, remote publication or clock-frequency claim is included.
