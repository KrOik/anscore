# ISP-14 CCM + tone mapping `ccm_stream`

Streaming per-pixel color correction matrix followed by an optional
piecewise-linear tone map.  Same-size RGB stream in and out, elastic
`tdata/tvalid/tready` with `tuser`=SOF and `tlast`=EOL passthrough (markers
are transported, not decoded — the core has no geometry parameters).
Channel `c` occupies `tdata[c*BITS +: BITS]` (c0=B LSB, c1=G, c2=R),
matching `isp/csc_stream.v` and `basic_isp` packing.  `BITS` in {8, 10};
other values `$fatal`.

## Datapath (II=1, latency 5 accepted edges)

    x_j   = unsigned input channel j                (0 .. MPX)
    acc_c = sum_j M[c][j] * x_j + (bias_c << 13)    exact integer, Q2.13 scale
    q_c   = clamp(round_half_away(acc_c / 2^13), 0, MPX)
    y_c   = tone_en[c] ? PWL(q_c) : q_c

- `M[c][j]`: signed **Q2.13** coefficient, 16-bit field, encodable range
  [-4.0, +4.0).  Supported envelope (commit-time legality): every output row
  must obey `sum_j |M[c][j]| <= ROW_GAIN_MAX = 7.0` (i.e. `7<<13`).
  This covers real camera CCMs (e.g. XYZ->sRGB's worst row
  3.24+1.54+0.50 = 5.28) and bounds the accumulator.
- `bias_c`: signed 16-bit offset in pixel units, applied in the Q2.13 domain
  before the single quantization boundary (range [-32768, 32767] pixels).
- Intermediate ranges: `|x*c| <= 1023*32768 = 2^25`; worst row magnitude
  `<= 1023*(7<<13) + 32767*2^13 < 2^30`; the 32-bit accumulator keeps ~2
  guard bits.  There is exactly one rounding point (`quantize`, round
  half-away-from-zero at /2^13 — same convention as `csc_stream`) plus
  clamp to `[0, MPX]`.  No intermediate quantization anywhere else.
- The products are computed in *transposed accumulate* form,
  `sum_j x_j*c_j = sum_{k<15} 2^k*s_k - 2^15*s_15` with
  `s_k = sum_j c_j[k]*x_j` — the shift-add idiom of `csc_stream`, so the
  datapath uses **zero DSP/MULT primitives**.  Identical integer result to
  the direct per-product form.

## Tone curve and the two signal domains

Per channel, the tone stage is a 33-node piecewise-linear map over
`[0, MPX]` on 32 uniform segments (`idx` = top 5 bits, `frac` = low
`BITS-5` bits, `STEP = 2^(BITS-5)`):

    out = y0 + ((y1 - y0) * frac + STEP/2) >> (BITS-5)    (round-half-up)

Nodes must be non-decreasing and `<= MPX`, so `dy >= 0` and the
interpolation can never exceed `y1 <= MPX`: the stage needs no clamp.
`tone_en[c]=0` bypasses per channel.

**Linear-light vs encoded domain.**  The matrix output `q_c` is an unsigned
code value; typical CCM placement is linear-light data.  The requirement to
separately define the two domains is implemented as *two resident node
banks* in the configuration image:

- `lin` bank — intended semantics: the curve operates on **linear-light**
  code values (e.g. toe/shoulder compression of the post-matrix linear
  signal).
- `enc` bank — intended semantics: the curve operates on **encoded-domain**
  code values (e.g. gamma-encode style curves applied to already-encoded
  samples).

The committed `domain` bit (ctrl bit 3) selects which shadow bank is copied
into the single per-channel active table at the apply edge.  The arithmetic
is identical for both banks; the distinction is which curve is programmed
and what domain its node values express.  Switching domain is a one-word
`ctrl` write + commit — both banks stay resident, no re-upload needed.
`stat_domain` outputs the committed bit.  All six tables (3 channels x 2
banks) are legality-checked at commit even for tone-disabled channels.

## Configuration interface and atomic commit

Shadow-register model: `cfg_valid/cfg_ready` beats each write one 16-bit
word into the **shadow** bank; nothing changes in the datapath until
commit.  Address map:

| addr        | field                                                     |
|-------------|-----------------------------------------------------------|
| `0x00`      | ctrl: bit0-2 `tone_en[c]`, bit3 `domain`, bits15:4 = 0    |
| `0x01-0x09` | matrix c00,c01,c02,c10,..,c22 (signed Q2.13)             |
| `0x0A-0x0C` | bias0..bias2 (signed, pixel units)                        |
| `0x10-0x72` | `lin` nodes, flat `n = c*33 + i`                          |
| `0x80-0xE2` | `enc` nodes, same flat order                              |

Writes to any other address pulse `cfg_error` and leave the shadow
untouched.  `cfg_ready` is high whenever no commit is in flight
(`!pending_apply && !checking && !cfg_commit`); while a commit is in
flight writes stall — the shadow cannot be mutated between commit and
apply, so an apply always copies exactly the image that was validated.

Node range is enforced at **write time**: node fields are stored `BITS`
bits wide, so a node write with `cfg_wdata[15:BITS] != 0` is rejected on
its own beat (`cfg_error`, shadow entry unchanged).  The shadow therefore
can never hold a node `> MPX`; commit-time validation only needs the
monotonicity scan:

- `ctrl[15:4] == 0`                                       (immediate)
- per-row `sum|c| <= 7.0` (`ROW_GAIN_MAX`)                (immediate)
- every node non-decreasing, both banks                   (serial scan,
  one flat index per cycle for 99 cycles, sampling one node per bank and
  comparing against the previous sample; `checking`/`cfg_pending` high)

Immediate violations pulse `cfg_error` on the commit edge; node-scan
violations pulse it at scan end (up to ~100 cycles later).  A commit while
checking/pending is rejected the same way.  On a clean scan
`pending_apply` arms and `cfg_pending` stays high until apply.

**Update boundary = next SOF presentation with an empty pipe.**  Mid-frame
beats always complete under the old image; while `pending_apply` and a SOF
beat is presented, `s_tready` is held low, in-flight pixels (<=5) drain
under the old config, then the whole image copies shadow->active in ONE
edge and `cfg_done` pulses; the SOF is accepted on the next cycle under
the new config.  There is no frame-end marker, so an idle gap is
deliberately *not* treated as a boundary — a commit issued while idle
waits until the next SOF (guaranteed whole-frame atomicity; a stream
without SOF markers simply never switches).  The commit edge and apply
edge never take a pixel, so no pixel ever sees a mixed configuration.
Worst-case boundary deferral: ~99 scan cycles + up to 5 drain cycles +
1 held-SOF cycle.

Reset loads both shadow and active state with a legal default: identity
matrix (diag = 1.0 = 8192), zero bias, tone disabled, `domain=0`, identity
node tables — so the power-on path is pure passthrough and a commit issued
right after reset is legal.  `busy = cfg_pending || in-flight beats`.

## Stream/reset contract

Single `clk`, synchronous active-low `rst_n`; reset clears valid/marker/
outstanding/pending state.  `tvalid && !tready` holds data and sidebands at
both ports; valid never waits for ready; no fall-through; backpressure is
normal (bounded only by downstream).  No RAM, no clock enables on data.

## Latency / throughput

- II = 1 pixel/cycle sustained, no-stall latency 5 clocks
  (s1 selected sums -> s2 partial accumulations -> s3 row sums ->
  s4 quantize -> s5 tone map + output register).
- Tail drain <= 5 cycles after last input.  Commit->apply adds <= ~105
  cycles at the boundary only.

## Verification coverage (tests/test_ccm.py)

iverilog `-g2012 -Wall`, deterministic seeds, BITS in {8,10}: 7 frames
(1592 px) per case over random/gradient/checker/extremes content; identity
reset config passthrough asserted; signed-matrix + signed-bias saturation
and negative-clamp cases; dual-bank domain switching; legal commits at
inter-frame gaps **and** mid-frame (applies at next SOF); rejected configs:
non-monotone LUT (both banks), out-of-range node write (write-time
rejection), row-gain overflow, reserved
ctrl bits, unmapped address write, commit-while-pending; shadow-write
stalling behind pending apply; randomized valid/ready + long stall epochs;
held-output stability during stalls; 3 reset epochs + mid-stream reset +
post-reset passthrough; 4 mutation runs per case (data/sideband/count/
order) proving the checker rejects corruption.  `test_models.py` checks
the legality predicate, quantize semantics, passthrough, and a <=2 LSB
bit-exact vs float bound over 6000 random pixels/configs.

## Resources (isolated `synth_gowin -top ccm_stream`, mapped cells)

| config | LUT1-4 | ALU | MUX2_LUT5 | FF | DSP | BRAM |
|--------|-------:|----:|----------:|---:|----:|-----:|
| BITS=8  | 9184  | 1484 | 416 | 4160 | 0 | 0 |
| BITS=10 | 11136 | 1695 | 515 | 4982 | 0 | 0 |

LUT-class total (LUT1-4 + ALU + MUX2_LUT5, all counted as LUT-class cells)
is **11084** for BITS=8 and **13346** for BITS=10 — comfortably inside the
<=15K hard budget, with zero DSP/BRAM (the contract that motivated the
shift-add matrix).  Fabric LUT1-4 alone is 9.2K/11.1K.  See
`evidence/synth_*/summary.json`.  No `-family` flag, mapped-only numbers —
not a P&R or 27 MHz timing result.

## Limitations

- No P&R, timing-closure or board evidence yet; resources are mapped
  cell counts only.
- Frame-boundary atomicity requires tuser=SOF markers; markerless streams
  never apply commits (by design).
- Illegal commits are detectable but the node monotone scan delays the
  error pulse by up to ~99 cycles; out-of-range node values are instead
  rejected on the write beat (node fields are only `BITS` bits wide, so
  they cannot express `> MPX`).
- The 3x3 matrix is RGB-only (CH=3 fixed); gray/other channel counts are
  not supported.
- `domain` selects the active tone bank but performs no other semantic
  conversion — domain intent is carried by the table contents.
- Coefficients outside the per-row 7.0 gain envelope are rejected; this is
  the documented supported range, not the full [-4,4) encodable field.
