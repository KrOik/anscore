# Connected-Component Analysis (CCA) — specification

Status: RTL/model simulation validated (`iverilog -g2012 -Wall`), yosys
`synth_gowin` resource numbers collected. No P&R/timing/board evidence yet.

`rtl/cca_stream.sv` labels the foreground (binary `s_tdata==1`) pixels of a
raster-scanned frame with 4- or 8-connectivity (runtime `cfg_conn8`) and emits
per-region features: `area`, `sumX`, `sumY` (centroid = sums/area, division
left to the host — no divider on die), and bounding box `minX/maxX/minY/maxY`.

Architecture choice (ISP-09 allowed two-pass *or* streaming): **single-pass
streaming** labelling with a deferred union-find equivalence table and an
end-of-frame resolve pass. There is no unconditional II=1 claim; steady-state
pixel throughput is II=1 while input is continuous, but each frame ends with
a serial resolve pass that blocks the next frame (see "Latency").

## Interfaces

Pixel slave `s_tdata[0:0]/s_tvalid/s_tready` with `s_tuser`=SOF at (0,0) and
`s_tlast`=EOL at `x==W-1`. `s_tready = rst_n && run && (in_frame ||
!pending_frame) && (configured || pend_valid) && (!f_v || f_move)` — the
stream is blocked before the first config, during the drain after the last
pixel, and through the whole resolve pass. Sidebands are checked per pixel:
SOF mid-frame, orphan pixel, early/missing EOL each pulse `o_error` once and
raise the sticky frame flag `oerr` in that frame's summary beat.

Config bundle (one `cfg_valid && cfg_ready` beat): `cfg_width[XW:0]`,
`cfg_height[YW:0]`, `cfg_conn8`. An accepted bundle is *pending* and commits
atomically at the next accepted SOF — the SOF pixel already sees the new
config. `cfg_ready` drops while pending (`commit_edge` itself re-opens it for
one cycle so a follow-on bundle never straddles the swap). `cfg_done` pulses
on legal accept, `cfg_error` on rejection, never both.

Result master `m_tdata[RW-1:0]/m_tvalid/m_tready/m_tuser/m_tlast`. Per frame
the resolve pass emits `nregions` **region beats** (`m_tuser=0`) followed by
exactly one **summary beat** (`m_tuser=1`, `m_tlast=1`):

```
region : {label[LBLW], area[AW], sumX[SW], sumY[SW],
          minX[XW], maxX[XW], minY[YW], maxY[YW]}   (MSB first)
summary: low bits {oerr, ovf_eq, ovf_lbl, nalloc[LBLW], nregions[LBLW]};
         oerr at bit 2*LBLW+2, ovf_eq at 2*LBLW+1, ovf_lbl at 2*LBLW.
```

Regions are emitted in ascending resolved (root) label order; root labels are
the class minima. A frame with no foreground pixels emits only the summary
beat. Per-pixel re-labelled output is NOT produced (features only — see
Limitations).

## Scan algorithm (single pass)

The line buffer `linebuf[W_MAX]` stores the previous row's provisional
labels. At `fire(x,y)` the RAM reads `linebuf[x]`; at `proc(x)` (two accepts
later) the just-arrived read data is `U(x+1)` and doubles as the up-right
neighbour — the process stage therefore resolves a pixel only when its
right-hand successor has been accepted (`proc_go = pend_v && (x==W-1 ||
f_v)`), which is why a last-column pixel never waits. `prev_u`/`left_lbl`
shift registers supply `UL` and `L`; `x==0`, `x==W-1` and `y==0` force the
corresponding neighbours to 0. A read/write collision on `linebuf[0]`
(scan-write vs next-row read) requires `W>=3` — enforced as a config legality.

Neighbour sets are sorted ascending (zeros map to the all-ones sentinel) and
compacted to the distinct set `{n1..n4}` — duplicates may leave interior zero
holes; the resolve pass skips them. The pixel's provisional label is:

```
bg pixel           -> 0
n1!=0              -> n1            (min neighbour label)
else alloc<=NL     -> alloc; alloc++   (new label)
else               -> 0 + ovf_lbl    (dropped, see Overflow)
```

and is written to `linebuf[x]` for the next row. When the distinct set has
>=2 members the sorted set `{n1,n2,n3,n4}` is appended to `eqtab` (one write
per pixel — the merge event). Features accumulate on the provisional label
through a read/modify/write pipeline with a one-deep forwarding register
(`wr_lbl/wr_data`) covering the same-label same-cycle read/write hazard; a
new label writes an initialised record, no table clear needed.

## End-of-frame resolve pass

Entered once `pending_frame && !in_frame && pipeline drained` (input is
blocked until the summary beat is accepted):

1. **union apply** — per `eqtab` entry in scan order:
   `r1 = find(n1)`; for each nonzero `nj` in the entry:
   `r2 = find(nj)`; `parent[max(r1,r2)] = min(r1,r2)`; `r1 = min`.
   `find` is an iterative chain walk on the synchronous `parent` RAM
   (addresses are combinational Mealy outputs of the FSM; data lands one
   state later). All parent edges go strictly downward, so `find` is
   depth-bounded by `NL` hops and cannot loop.
2. **flatten** — `FPASS = clog2(NL+1)` pointer-doubling passes:
   `parent[i] <= parent[parent[i]]` for `i = 1..alloc-1`. Chains halve each
   pass, so after `FPASS` passes every entry is a root (class minimum by
   construction of the min-root union rule).
3. **merge** — for `i = 1..alloc-1` ascending: if `parent[i] != i`, fold
   `feat[i]` into `feat[root]` (area/sums add, bounds min/max). Sequential
   RMW, no port hazard. Roots are counted into `nregs`.
4. **emit** — for `i = 1..alloc-1` ascending: roots emit
   `{i, feat[i]}`; then the summary beat.

Label `i` is initialised (`parent[i]=i`, `feat[i]={1,x,y,x,x,y,y}`) at
allocation during the scan, so no RAM needs clearing between frames and stale
contents of unallocated entries are unreachable.

## Buffering / continuous frames

Bounded memories per frame: `linebuf` (W_MAX x LBLW), `parent` (NL+1 x LBLW),
`eqtab` (EQT x 4*LBLW), `feat` ((NL+1) x FW). Frame N+1 pixels are accepted
only after the summary beat of frame N has been taken — the required frame
gap equals the resolve+emit duration (data dependent; ~2 cycles per union
hop, ~3 per flatten element per pass, ~5 per merge/emit label, plus sink
stalls on `m_tready`). Config bundles may be queued during resolve and commit
at the next SOF.

## Overflow semantics

- **Label overflow**: foreground pixel with no labelled neighbour while
  `alloc > NL` is dropped (its `linebuf` entry is 0, so it cannot bridge
  neighbours either) and the sticky `ovf_lbl` flag is set in the frame
  summary. A dropped pixel can therefore split a region — overflowed frames
  are flagged, results are best-effort.
- **Equivalence (merge-event) overflow**: a merge event while
  `eq_cnt == EQT` is dropped and `ovf_eq` is raised; the partition may then
  stay split. Both flags and `nalloc`/`nregions` appear in the summary beat.
- `oerr` accumulates `o_error` protocol violations seen during the frame.

Widths: `LBLW=clog2(NL+2)` (sentinel room), `AW=clog2(W_MAX*H_MAX)+1`,
`SW=AW+XW` (sumX/sumY cannot overflow: `sumX <= (W_MAX-1)*W_MAX*H_MAX`),
`FW=AW+2*SW+2*XW+2*YW`, `RW=LBLW+FW`.

## Config legality (rejected with cfg_error, no state change)

`width<3`, `width>W_MAX`, `height<1`, `height>H_MAX`. `conn8` is
unconstrained. Static `$fatal` checks: `W_MAX>=3`, `H_MAX>=1`,
`2<=NL<=254`, `EQT>=1`.

## Verification

`python cores/signal_processing/dsp_isp_library/isp/cca/tests/test_cca.py`

Five deterministic seeded cases run under 3 epochs (full rate / sink stalls /
sparse source) plus a mid-emit-stall reset tail and an orphan-pixel protocol
check: random frames with conn8/conn4 mix and dim changes (55 regions),
known shapes incl. a U-merge and a diagonal exercising the 4-vs-8 difference,
`NL=8` label overflow on a 4-conn checkerboard, `EQT=8` merge-event overflow
on an 8-conn checkerboard, minimum-size 3x4 frames. Assertions: bit-exact vs
`models/model.py` on every beat (label ids, area, centroid sums, bbox,
overflow flags), II=1 on consecutive in-frame accepts at full rate, held
outputs stable under stalls, cfg backpressure exercised (`cfgwait>0`), all
mutations (data/sideband/order/count) detected, illegal dims rejected
(`width 0/1/2/257`, `height 0/300`), static params rejected
(`NL=1`, `NL=300`, `W_MAX=2`, `EQT=0`).

Evidence: `evidence/sim_<ts>/summary.json`, per-case compile/run/negative
logs, source hashes.

## Synthesis

`python cores/signal_processing/dsp_isp_library/isp/cca/synth_cca.py`
(`yosys read_verilog -sv` + `synth_gowin -top cca_synth_top`, no -family)

| config                    | LUT  | FF  | DSP | BSRAM    | ALU |
|---------------------------|------|-----|-----|----------|-----|
| 256x256 NL=128 EQT=256    | 1388 | 906 | 0   | 5x DPX9B | 386 |
| 256x256 NL=64  EQT=128    | 1257 | 875 | 0   | 5x DPX9B | 366 |
| 64x64   NL=32  EQT=64     | 1249 | 569 | 0   | 0        | 298 |

Well inside the <=15K LUT / <=4 DSP target. Timing/P&R not run.

## Limitations

- No per-pixel label map output: the choice was feature-only emit (documented
  option). Re-labelling pixels would require a second pass over a stored
  label frame — a different (frame-buffered) architecture.
- Centroid is delivered as raw `sumX`/`sumY`/`area`; division is off-chip.
- Resolve latency is data-dependent (union find chain depth); bounded by
  `O(eq_cnt * NL + FPASS * alloc + emit)` — pathological chains can make the
  frame gap ~10^5 cycles at NL=128.
- Streaming pipeline needs `W>=3` (line-buffer read/write hazard at column 0).
- Overflows flag and degrade rather than guarantee correctness: a dropped
  merge event or dropped pixel can split regions. Size NL/EQT for the
  application or treat flagged frames as invalid.
- Single `clk`, synchronous `rst_n`; reset drops in-flight frame, pending
  config and resolve state. RAMs are not cleared — all consumed entries are
  written before use within a frame.
- Equivalence entries keep interior zero holes after dedup (e.g.
  `{4,0,5,0}`); the resolve pass skips zero slots — this is a documented
  encoding, not a bug.
