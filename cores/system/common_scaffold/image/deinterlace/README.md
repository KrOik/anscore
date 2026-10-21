# Paired-field grayscale deinterlacing

`deinterlace_fields.sv` turns two temporally ordered grayscale fields into one
progressive raster using WEAVE, linear BOB, or a simple local adaptive choice.
It performs all interpolation and decisions in synthesizable RTL, with a
synchronous-read frame RAM. It does not implement motion compensation, YADIF,
BWDIF, edge-directed interpolation or automatic field-order detection.

## Geometry and temporal order

WIDTH/HEIGHT describe the **progressive output**, not a field. Top parity0
contains full-frame rows 0,2,4,... and has ceil(HEIGHT/2) lines. Bottom parity1
contains rows 1,3,5,... and has floor(HEIGHT/2) lines. Each field is presented
as its own raster, left-to-right, then increasing its full-frame row by two.
`s_field_sof` is true on the first pixel of **each field**, `s_eol` at every
field-line end; `s_parity` must match that field on every pixel.

Present the complete **older** field first and the complete **newer** opposite
parity field second. `cfg_first_parity` says whether the older field is top0 or
bottom1; the BOB reference is always the newer field. Thus top-first selects
newer bottom lines and bottom-first selects newer top lines. The design never
silently substitutes a fixed top reference. There is one progressive output per
field pair, not one per field. Output x/y coordinates are implicit raster order.

For odd heights, top has one more line. The expected number of pixels in each
field follows its parity, including bottom-first ordering. For HEIGHT=1, the
bottom field is empty: send **only the top field**, with s_parity=0. In this
degenerate case cfg_first_parity is ignored (both 0 and 1 are tested), all modes
emit the captured top row, and no interpolation is reported.

Supported WIDTH/HEIGHT=1..4096, product <=65536, unsigned BITS=8..12. Parameter
validation uses an explicitly 64-bit pixel product. The logical memory contains
WIDTH*HEIGHT*BITS bits; a large supported geometry can exceed a particular
board's physical BRAM capacity. Maximum logical geometry is not a claim of
Tang 20K resource fit for a full-sized image.

## Modes and exact formulas

`cfg_mode`, `cfg_first_parity` and `cfg_threshold` are sampled together on the
first accepted pixel of a pair. Later live changes have no effect. cfg_mode=3
is explicitly rejected with error_code=2 at a new pair; it does not alias WEAVE.

- **0 WEAVE:** output every captured pixel at its original full-frame row.
  This preserves spatial detail but combines the two capture times.
- **1 BOB:** preserve every newer-field line exactly. On each missing line,
  use the two neighboring newer-field lines:
  `bob=floor((upper+lower+1)/2)`. At a top/bottom boundary where only one newer
  neighbor exists, replicate that neighbor for both upper and lower.
- **2 ADAPTIVE:** preserve newer-field lines exactly. On a missing line, form
  the same bob value, and calculate `d=abs(older_pixel-bob)`. Use bob iff
  `d>cfg_threshold`; otherwise use the older pixel (WEAVE). Threshold is an
  unsigned intensity difference; equality keeps WEAVE. This is a local
  cross-field consistency heuristic, not a temporal motion estimator.

`m_bob_used` identifies an interpolated record, even if its value happens to
equal the weave candidate. It is zero for all preserved newer lines, WEAVE,
and HEIGHT=1. Fullscale addition uses BITS+1 bits: upper+lower+1 <=2^(BITS+1)-1,
so the half-up average cannot overflow. Absolute difference fits BITS bits.

On static linear vertical intensity, the interior BOB result agrees with the
original raster. On a static fine horizontal edge, the adaptive consistency
test can also choose BOB and soften detail. Motion and vertical detail can be
ambiguous with two fields; no claim of universal comb detection is made.
Synthetic temporal-comb fixtures verify that WEAVE retains old/new stripes,
whereas BOB/adaptive select the newer uniform image. Moving-bar and random
fixtures exercise choices separately for both temporal parity orders.

## Handshake, errors and recovery

Transfers require **rst_n && ce && valid && ready** on the rising edge. Reset is
synchronous active low, overrides CE, and aborts pending capture/computation/
output. Do not count transfers during reset even if combinational ready is
high. RAM does not need reset; complete new capture overwrites it before output.

Capture accepts one pixel per enabled cycle. Both fields are stored into their
interleaved full-frame locations in a single RAM, then output processing starts.
s_ready is low during processing/output; pairs do not overlap. Source gaps,
CE pauses and output backpressure are supported. Every output field
(m_pixel/m_bob_used/m_sof/m_eol/m_valid) remains stable while held. busy covers
partial capture through the final output handshake.

Wrong parity, SOF or EOL aborts with error_code=1 and a done pulse, resets the
capture coordinates and immediately permits a new complete pair. No output is
emitted from a bad capture. A legal first pixel clears the error. Defensive
illegal-state recovery reports error_code=3. done pulses for one **enabled
cycle** after either an abort or the final output transfer; CE=0 holds a pulse.
There is no separate completion handshake. Integrators must sample done with
CE qualification, and treat error_code as persistent until new good input.

After entering per-pixel processing, WEAVE or a preserved newer line asserts
m_valid after three enabled edges. A missing BOB/adaptive line asserts it after
eight enabled edges. With immediate output acceptance the output intervals are
four and nine enabled edges respectively. The first output after final capture
uses the appropriate same latency. This serial frame-buffered architecture
does not claim pixel-rate or real-time video throughput.

## Reproduce and evidence

```powershell
python -B cores/system/common_scaffold/image/deinterlace/test_deinterlace.py
python -B cores/system/common_scaffold/image/deinterlace/synth.py
```

Independent Python integer models check every output intensity, BOB flag and
marker. Current regression: **448 pairs / 6784 pixels / 1142 BOB records**, plus
five invalid-parameter cases, all PASS. It covers both temporal orders, modes,
maximum threshold, zero/fullscale, static ramps, combs, moving bars, random
fields, BITS8/10/12, thin/singleton/two-line/odd geometries, first-pixel config
snapshots, CE/source gaps/output stalls, SOF/EOL/parity faults, early top-field
termination, overlong odd-height bottom field, complete good replay after
faults, and reset with CE=0 during capture, synchronous-read and held output.
Ten comb scenarios explicitly demonstrate mode differences.

Isolated Gowin `synth_gowin -noalu -nodsp`, 16x12 geometry, reports CHECK zero
problems:

| BITS | LUT1..4 | FF | MUX5 | RAM | DSP |
|---|---:|---:|---:|---:|---:|
| 8 | 271 | 113 | 32 | 1 DPX9B | 0 |
| 12 | 319 | 133 | 43 | 1 DPX9B | 0 |

These isolated estimates meet 15K LUT/4DSP for the reported configurations.
No place/route, board programming, timing closure or board acceptance is
claimed. Temporary testbenches, vectors and binaries are automatically removed
with TemporaryDirectory. Compact JSON evidence and synthesis logs remain.

## Public reference and scope

Actually fetched [FFmpeg filters documentation source](https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/doc/filters.texi),
sections `yadif` and `bwdif`; reference.json records the source SHA256 and exact
excerpts. These document temporal field parity and frame/field output choices.
BWDIF additionally uses YADIF-derived motion-adaptive logic, w3fdif and cubic
interpolation. This independently implemented two-field local threshold method
does not reproduce those algorithms or their quality/performance. No FFmpeg
source code was incorporated.
