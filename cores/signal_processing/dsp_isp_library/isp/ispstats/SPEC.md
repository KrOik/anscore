# ISP-12 AE/AWB/AF statistics core `ispstats_stream`

Streaming raster statistics **sink** computing, per frame, a record set of
zoned statistics for auto-exposure / auto-white-balance / auto-focus host
algorithms.  There is deliberately **no pixel output stream and no control
output**: the requirement is statistics plus an independent result interface.
AE *control* needs camera-interface evidence this core does not provide; the
offline suggestion functions in `models/ae_analysis.py` are host-side
analysis models only (see `goal.md` ISP-12 wording and §Limits).

## Data formats

`BITS` in {8, 10} unsigned.  `CH` in {1, 3} is a **static** parameter:

- `CH=1` gray: `s_tdata[BITS-1:0]` = pixel luma.
- `CH=3` packed RGB: `s_tdata = {R, G, B}` MSB->LSB (`R` in bits
  `3*BITS-1:2*BITS`), matching `isp/csc_stream.v` channel order.

Image geometry is runtime configuration `img_w` in [1, MAX_W], `img_h` in
[1, MAX_H]; static bounds `MAX_W`,`MAX_H` in [1,1024] and
`MAX_W*MAX_H <= 65536` (covers all qualification sizes 1x1, 2x2, 7x5,
32x24 up to e.g. 256x256).

## Zone grid

Runtime `zones_x` x `zones_y`, each in [1,8], with legality constraint
`zones_x <= img_w` and `zones_y <= img_h` so every zone is non-empty.
Column zone of pixel `x` is `zx = floor(x*zones_x/img_w)`; row zone of `y`
is `zy = floor(y*zones_y/img_h)`.  The RTL derives this with a single-carry
Bresenham accumulator (`acc += zones; if acc >= dim { acc -= dim; z++ }`),
which `models/reference.py` proves identical to the floor map for every
legal `(dim, zones)` pair with `dim <= 64`; equivalence for all legal
configurations follows because `zones <= dim` bounds the carry to 1.

## Per-zone record (the integer contract, shared with `models/reference.py`)

For each accepted pixel, let `v` be the luma-path value

    v = pixel                        (CH=1)
      = (r + 2*g + b) >> 2           (CH=3; exact floor, <= MPX)

and the focus gradient is the causal first-difference magnitude

    gx(x,y) = 0                       if x == 0, else |v(x,y) - v(x-1,y)|
    gy(x,y) = 0                       if y == 0, else |v(x,y) - v(x,y-1)|
    e(x,y)  = gx + gy                 <= 2*MPX, attributed to zone(x,y)

The overexposure flag is `over(x,y) = max(channels) >= cfg_thresh`
(any-channel clip detect; gray: `pixel >= thresh`).

Each zone record, emitted at the zone's final pixel (last column of the
zone on the last row of its band), is

    count  : pixels in zone                          [CNTW]
    sum0/1/2 : channel sums R/G/B (gray: sum0 only,  [SUMW] each
               sum1 = sum2 = 0)
    oe     : overexposed pixel count                 [CNTW]
    focus  : sum of e(x,y) over the zone             [ENW]

Result word packing MSB->LSB: `{focus, oe, sum2, sum1, sum0, count}`,
`RW = 2*CNTW + 3*SUMW + ENW` bits.

### Accumulator widths — no overflow by construction

Zone ⊆ frame, so every field is bounded by a full frame of worst-case
contributions; no runtime saturation exists or is needed:

| field | bound | width |
|---|---|---|
| count | ≤ FP | `CNTW = clog2(FP+1)` |
| sum_c | ≤ FP·MPX | `SUMW = clog2(FP·MPX+1)` |
| oe | ≤ FP | `CNTW` |
| focus | ≤ FP·2·MPX | `ENW = clog2(FP·2·MPX+1)` |

`MPX = 2^BITS − 1`, `FP = MAX_W·MAX_H`.  Each update adds at most
`{1, MPX, 1, 2·MPX}` to a value already below `bound − increment`, so the
registered accumulators can never wrap.  (Overflow is excluded by
construction, mirroring the ISP-10 proof style.)

## Interfaces and timing

Single `clk`, synchronous active-low `rst_n`.

**Input** `s_tdata/s_tvalid/s_tready` + `s_tuser`(SOF at (0,0)) +
`s_tlast`(EOL at `x = img_w−1`).  The core is a pure sink: it accepts every
cycle (`II=1` unconditionally) except the single cycle an atomic config
commit blocks a new frame start (`s_tready = rst_n && !(cfg_valid &&
cfg_ready)`).

**Marker checking**: input `tuser`/`tlast` are compared against the
configured geometry on every accepted pixel; violations set sticky
`marker_error` (until reset) and do not resynchronize — position counters
keep their raster contract, so a malformed stream still produces a record
set whose values reflect the accepted pixels.

**Result readout** (independent of the input stream): a dual-bank
ping-pong record RAM.  Zone record `i` (push order = `zy`-major,
`zx`-minor) lands at `{bank, addr=i}` the cycle its zone's last pixel
commits.

- `res_new` pulses one cycle after the final accepted pixel of a frame
  (the last zone-final pixel is the frame's last pixel); `res_new_bank`
  names the bank written.
- `res_done[b]` marks a bank holding a complete frame's record set;
  `res_frame`/`res_count` give each bank's frame sequence number
  (mod 256) and record count (`zones_x*zones_y`).
- `res_done[b]` clears when a frame *starts* writing bank `b`, so a
  completed frame's records remain valid for one full following frame.
- Host read: present `res_bank`,`res_addr` at edge T; `res_data` is valid
  in cycle T+1 (synchronous read port) and holds while the address and the
  bank's frame identity are unchanged.  There is no read flow control and
  no overflow path — a slow host simply sees `res_frame[b]` advance.

**Latency**: complete record set committed 1 cycle after the last accepted
input pixel; readable one further cycle after the address is presented.
No drain phase; back-to-back frames may start immediately (a frame's SOF
can coincide with the previous frame's last-pixel commit).

**Atomic config** (`cfg_valid/cfg_ready`, all fields committed or rejected
together): `cfg_img_w`, `cfg_img_h`, `cfg_zx`, `cfg_zy`, `cfg_thresh`.
`cfg_ready` asserts only between frames (`busy` low = `fopen | pend`), so
a held request waits for the frame gap; legal updates pulse `cfg_done`,
out-of-range fields pulse `cfg_error` and leave the configuration intact.
Rejected: `img_w`/`img_h` out of [1,MAX], `zones_*` outside [1,8] or
exceeding the image dimension.  `cfg_thresh` is `BITS` wide so it is
always in range.  Reset default: `img = MAX_W×MAX_H`, `zones =
min(4,MAX_*)×min(4,MAX_*)`, `thresh = MPX` (only saturated pixels count).

**Reset** clears valid/control state and the 8 band accumulators (they are
registers, not RAM).  The luma line RAM and result RAM are not cleared;
stale contents are masked by `res_done`/`cap_y0` validity rules, so
uninitialized RAM can never reach a result.  A mid-frame reset discards
the partial frame: its bank stays `res_done = 0`, and the next frame
starts a fresh record set.

## Architecture

Per accepted pixel the core performs O(1) work — the II=1 contract is
honest for every legal grid/image:

1. **Zone map**: Bresenham accumulators `acc_x`/`acc_y` yield `zx`,`zy`,
   `col_last`, `band_last` combinationally per pixel.
2. **Luma line buffer** `lummem[0:MAX_W-1]` (`ram_style="block"`): read at
   the take edge (read-before-write with `v` write-back) supplies
   `v(x,y−1)` for `gy`.
3. **Band accumulators** `a_*[0:7]` (registers): the *current* band's
   zone-column sums; pixel contributions fold into `a_*[cap_zx]` at the
   commit edge.  On a zone-final pixel the record `{n_en,n_oe,n_s2,n_s1,
   n_s0,n_cnt}` pushes into `resmem` and the slot clears — so the record
   store is written at most once per pixel and read-modify-write hazards
   do not exist.
4. **Ping-pong result RAM** `resmem[0:127]` (`ram_style="block"`): bank
   `wbank` written by pushes; the host port reads the other bank.
   `sof_bank` handles a SOF coincident with a previous frame's commit by
   clearing `~wbank` — the bank that frame will write.

Pipeline: stage A (take edge) captures the pixel and issues the luma-line
read; stage B commits the accumulator update/push on the next edge.

## Throughput

- Input `II=1` sustained for any legal configuration; the only input stall
  is a one-cycle deferral while an atomic config commit has priority at a
  frame gap.
- Result pushes are sparse (≤ `zones_x` per band-last row); the result RAM
  write rate can never exceed one per cycle and never stalls input.
- `busy` covers mid-frame input gaps and the one-cycle commit tail, so a
  config can never land inside a frame.

## Resource summary (isolated `synth_gowin -noalu -family gw2a`)

See `ip_manifest.json` and `evidence/synth_*/summary.json`.
Qualification-scale builds are ≈2.0K LUT, ≈1.1K FF, **0 DSP**, ≤5 BRAM
(luma line + dual-bank record RAM).  Worst measured (10-bit, 256×256 bound)
≈2.9K LUT / 1.6K FF / 5 BRAM — far inside the 15K-LUT/4-DSP budget.

## Limits

- Statistics and offline analysis only; **no closed-loop AE/AWB/AF claim**:
  `models/ae_analysis.py` computes suggestions from a record set without
  camera evidence.
- Focus operator is a causal first-difference gradient, not a full 3×3
  Sobel: it needs one line buffer only, and `x==0`/`y==0` borders
  contribute 0 by definition.
- `zones_x > img_w` / `zones_y > img_h` (empty zones) are rejected as
  illegal configurations rather than producing zero-count records.
- A host must read a bank within one following frame or `res_frame[b]`
  advances (records are not flow-controlled).
- Malformed marker streams flag `marker_error` but are not resynced.
- No P&R, timing or board claim yet; RAM inference follows the same
  `ram_style="block"` pattern as the window foundation.
