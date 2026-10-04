# ISP-15 chroma resampling & pixel packing `isp/chroma`

Streaming cores for 4:4:4 <-> 4:2:2 <-> 4:2:0 chroma format conversion and
sample<->word packing.  Everything here is bit-exact against
`models/model.py`; simulation evidence in `evidence/sim_*`, isolated
`synth_gowin` (no `-family`) maps in `evidence/synth_*`.

```
rtl/chroma_422.sv   4:4:4 -> 4:2:2   (horizontal anti-alias decimation)
rtl/chroma_420.sv   4:4:4 or 4:2:2 -> 4:2:0  (chroma420_v vertical stage +
                                            optional internal chroma_422)
rtl/pix_pack.sv     pix_pack + pix_unpack (8/10-bit sample <-> word)
```

## Stream / config / reset contract

Single `clk`, synchronous active-low `rst_n`.  Image sidebands: `tuser` =
SOF at pixel (0,0), `tlast` = EOL at the last beat of each line.
`tvalid && !tready` holds data and sidebands stable (checked in TB).
`marker_error` is a sticky flag, cleared only by reset; it asserts on any
accepted beat whose `tuser`/`tlast` does not match the static
`WIDTH`/`HEIGHT` geometry, including missing SOF and wrong-position EOL.

Config: `cfg_valid`/`cfg_ready` handshake, accepted only while the core is
idle (between frames), `cfg_done` on commit, `cfg_error` on illegal values
(`cfg_siting` > 1); an illegal commit leaves the active configuration
untouched (proved by a retained-config frame replay in the TBs).  A pending
`cfg_valid` delays the next input by one cycle so commits never coincide
with a take.  Reset default siting = 0 (co-sited).

## Formats and geometry

`BITS` in {8, 10} per component, unsigned.  4:4:4 input pixel word is
`{Y, Cb, Cr}` MSB->LSB, matching `isp/csc_stream.v` channel order.

### chroma_422 output packing (interleaved pair word)

One beat per chroma column pair, `OW = ceil(W/2)` beats per line:

```
m_tdata = { Y_even , Cb , Y_odd , Cr }          MSB -> LSB
                serialized MSB-first this is byte order Y0 Cb Y1 Cr (YUYV)
```

### chroma_420 output packing (tagged interleaved beats)

One beat per output unit, `m_tdata = {tag, A, B}`:

```
tag 0 : {Y_even, Y_odd}    luma pair of the current 2-pixel column pair
tag 1 : {Cb, Cr}           decimated chroma for the 2x2 block
```

Per input line the beat group is terminated by `tlast`:

```
even line y (not last of odd-H frame): {0,Ye,Yo} x OW          <- luma only
odd line y (or last line when H odd):  ({0,Ye,Yo},{1,Cb,Cr}) x OW
```

This is a documented interleaved packing: chroma words are distinguishable
by the tag bit, luma rate is preserved (1 sample/pixel), chroma rate is
1/4 sample/pixel/component.  A planar consumer can demultiplex on `tag`;
`pix_unpack`/`pix_pack` provide the byte-word adaptation underneath.

### pix_pack / pix_unpack

`pix_pack` groups `NS` (1..8) stream samples of `BITS` bits into one word of
`NS*SLT` bits, `SLT = max(SLOT, BITS)`, `SLOT` in {0, 8, 16}:

```
SLOT=0         : tight packing  (4x8 -> 32b, 4x10 -> 40b)
SLOT=8/16      : per-sample pad (10b -> 16b slot: 2x10 -> 32b, 4x10 -> 64b)
```

First sample occupies the MSB slot.  Input `tlast` flushes a partial group:
remaining low slots are zero, output `tlast` propagates, output `tuser`
comes from the group's first sample.  `proto_error` (sticky) flags a `tuser`
inside an unfinished group.  `pix_unpack` re-expands each word to `NS`
samples MSB->LSB (`tuser` on slot 0, `tlast` on slot NS-1); a flushed word
therefore emits its zero pad samples too - count-preserving per word, not
per original group.

## Chroma siting (sampling phase)

Horizontal, selectable per frame via `cfg_siting`:

```
siting 0  co-sited left (JPEG/MPEG-1):
    luma   x:  0   1   2   3   4   5 ...
    chroma :  C0       C1       C2          C_i centred ON column 2i
    filter : [1,2,1]/4 over columns {2i-1, 2i, 2i+1}

siting 1  centre (MPEG-2):
    luma   x:  0   1   2   3   4   5 ...
    chroma :    C0       C1       C2        C_i midway between 2i and 2i+1
    filter : [1,3,3,1]/8 over columns {2i-1, 2i, 2i+1, 2i+2}
```

Vertical (4:2:0 only, fixed in this revision):

```
    line y :  0   1   2   3 ...
    chroma :  R0      R1               R_j co-sited with even line 2j
    filter : [1,2,1]/4 over lines {2j-1, 2j, 2j+1}
    (chroma beats for group j are emitted while line 2j+1 streams)
```

All edges use replicate extension: out-of-range taps clamp to the edge
sample (equivalently the weight folds onto the edge tap), so filter gain
stays exactly 1.0 at frame borders - verified bit-exact vs the model for
every corner including W=1 / H=1.

### Filter choice & frequency response

The reference anti-alias filters are the short symmetric binomials
`[1,2,1]/4` and `[1,3,3,1]/8` - real convolution, not sample dropping:

- `[1,2,1]/4`:  |H(w)| = (1+cos w)/2.  At the post-decimation Nyquist edge
  (w = pi/2 in input-rate units) gain = 0.5 (-6 dB); 0 dB at DC.
- `[1,3,3,1]/8`: |H(w)| = cos^3(w/2).  At w = pi/2 gain ~0.354 (-9 dB).

These are honest but deliberately short filters: chroma edges with energy
above half the new Nyquist will alias mildly (bounded ~-6/-9 dB at the
edge).  That is the documented reference configuration; stronger
anti-alias rejection needs a longer filter, which would be a parameter
upgrade, not an interface change.  The float model in `models/model.py`
(exact rational taps, unquantized output) bounds the rounding error of the
integer path at <= 0.5 LSB per stage (asserted in the regression).

## Odd-size policy (defined, tested at W/H = 1..9)

- Odd WIDTH: the last column pair is a single pixel.  The pair word's
  `Y_odd` slot carries a replicate of the last luma (documented padding;
  consumers that know W ignore it).  The chroma tap that would address
  column W clamps to column W-1.
- Odd HEIGHT (4:2:0): the last line group is one line; the missing odd line
  of the vertical filter replicates the last even line
  (`v = (A + 3*B + 2) >> 2`), and the chroma beats ride on the last line's
  group (tag 1 beats after the luma beats).
- W=1 / H=1 degenerate frames are legal; chroma output equals the input
  chroma (all taps clamp to the single sample) - checked.

## Rate contract / II

| core      | input                                  | output beats per frame              | sustained input rate |
|-----------|----------------------------------------|-------------------------------------|----------------------|
| 444->422  | W*H pixels                             | ceil(W/2)*H pair words              | II=1 pixel/cycle     |
| 444->420  | W*H pixels                             | ceil(W/2)*H luma + ceil(W/2)*ceil(H/2) chroma | ~1 px/cycle even lines, 2/3 px/cycle on chroma lines |
| 422->420  | ceil(W/2)*H pair words                 | same as above                       | 1 pair / 2 cy (even), 1 pair / 3 cy (chroma lines) |
| pix_pack  | NIN samples                            | one word per NS samples (+tlast flush) | II=1 sample/cycle |
| pix_unpack| NIN words                              | NS samples per word                 | 1 word / NS cycles   |

Per-component sample rates (normalized to input pixels):

```
4:4:4  Y=1.00  Cb=1.00  Cr=1.00   -> 3.00 samples/pixel
4:2:2  Y=1.00  Cb=0.50  Cr=0.50   -> 2.00 samples/pixel
4:2:0  Y=1.00  Cb=0.25  Cr=0.25   -> 1.50 samples/pixel
```

Notes:

- `chroma_422` emits one beat per two input pixels on average; the only
  2-beats-for-1-input corner (centre siting + odd WIDTH + last column)
  parks the second beat in a skid register and deasserts `s_tready` until
  it drains - never a silent drop.
- `chroma420_v` holds each accepted pair beat until its 1 or 2 output beats
  are emitted, so on chroma-bearing lines the effective pair pitch is
  3 cycles; on luma-only lines 2 cycles (full pair rate).  This is the
  honest consequence of two output words per input word - documented, not
  hidden.
- Latency: 422 first output coincides with the input beat that completes
  the tap window (x==1 co-sited; x==2 or EOL centre).  420 adds +1 cycle
  for the synchronous line-buffer read.  Output `tuser`/`tlast` track the
  emitted beat, not the input.

## 4:2:0 chroma line buffer budget

`chroma420_v` keeps exactly one chroma line as budgeted: `cmem` depth
`ceil(W/2)`, width `4*BITS` (entry = {A,B} = {previous odd-line chroma,
this-group even-line chroma}, each {Cb,Cr}).  Synchronous single-buffered
SDP pattern (one registered read, one write).

| WIDTH | BITS | buffer bits | mapped (synth_gowin, no -family) |
|-------|------|-------------|--------------------------------|
| 64    | 8/10 | 2K          | 16 x RAM16SDP4 (LUT RAM)         |
| 1920  | 8    | 30,720      | 2 x DPX9B (BSRAM)              |

A luma line buffer is deliberately avoided by the tagged-interleaved output
packing (luma pairs go out with the line they arrived on).

## Resources (isolated `synth_gowin -top`, no `-family`, no P&R)

| config | LUT1-4 | FF | DSP | BRAM/LUTRAM |
|---|---|---|---|---|
| chroma_422  W=32  H=24  8b  | 571 | 161 | 0 | 0 |
| chroma_422  W=64  H=48  10b | 708 | 198 | 0 | 0 |
| chroma_422  W=1920 H=1080 8b| 579 | 179 | 0 | 0 |
| chroma_420  W=32  H=24  8b src444 | 606 | 267 | 0 | 8x RAM16SDP4 |
| chroma_420  W=64  H=48  10b src444| 787 | 328 | 0 | 16x RAM16SDP4 |
| chroma_420  W=64  H=48  8b src422 | 149 | 112 | 0 | 16x RAM16SDP4 |
| chroma_420  W=1920 H=1080 8b src444| 663 | 277 | 0 | 2x DPX9B |
| pix_pack    8b NS=4 tight   | 53 | 74 | 0 | 0 |
| pix_pack    10b NS=4 tight  | 61 | 90 | 0 | 0 |
| pix_pack    10b NS=2 SLOT16 | 36 | 50 | 0 | 0 |
| pix_unpack  8b NS=4 tight   | 37 | 50 | 0 | 0 |
| pix_unpack  10b NS=2 SLOT16 | 23 | 40 | 0 | 0 |

All configurations are far under the 15K-LUT / 4-DSP ceiling; no
multipliers are used at all (the filters are shift-add).

## Verification

`tests/test_chroma.py` (iverilog `-g2012 -Wall`, deterministic seeds):

- 12 x chroma_422 cases: odd/even/min geometry, 8 & 10 bit, per-frame
  siting switches through the real config handshake, 3 epochs
  (full-speed / random ready / random valid gaps), 4 frames each.
- 13 x chroma_420 cases: SRC422=0 (chained h+v) and SRC422=1 (422 word
  input), odd/even W and H incl. 1x1, same protocol/mutation coverage.
- 9 x pix_pack cases: pack->unpack chained, tight + SLOT=8/16 padding,
  partial-group `tlast` flush.
- Every case gets 4 checker-mutation negative runs (+data, +order,
  +count, +sideband) plus illegal-parameter `vvp` rejections
  (12 configs: BITS, WIDTH, HEIGHT, SRC422, NS, SLOT, SLOT<BITS).
- TBs also check stall payload stability, terminal `busy`, illegal
  `cfg_siting=3` rejection + retained-config replay, and the sticky
  `marker_error` diagnostic.

## Limitations / non-goals

- Static `WIDTH`/`HEIGHT` module parameters (not runtime registers);
  `marker_error` enforces them against the incoming sidebands.
- Vertical 4:2:0 siting is fixed co-sited-top [1,2,1]/4 in this revision;
  a centre-sited vertical phase would need a second chroma line of history
  (documented design space, not implemented).
- Decimation only; there is no 4:2:2/4:2:0 -> 4:4:4 reconstruction core
  (the requirement's "conversions" are delivered as the sub-sample
  direction; upsampling would be a separate interpolation module).
- `cfg_siting` on SRC422=1 `chroma_420` is accepted/stored but unused
  (horizontal phase belongs to the upstream 422 stage) - documented, not
  silently functional.
- `pix_unpack` re-emits the zero pad of a flushed word (per-word
  count-preserving); consumers needing original group length must track
  input tlast or frame geometry.
- No P&R, timing closure or board evidence yet - isolated `synth_gowin`
  maps only.
