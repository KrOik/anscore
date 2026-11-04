# Exact grayscale max-tree and upper-component areas

`grayscale_max_tree` converts a real unsigned grayscale raster into its complete
upper-level connected-component hierarchy. It returns the parent relation,
canonical-node membership and exact component areas. This provides a reusable
region hierarchy for attribute selection and multilevel segmentation. It does
not require host labels, a prebuilt tree or filtered pixels as input.

Baseline: `ed4eda4fe213da6f6fec793ef911daaabfeba2cc`. The actual qualification
status and complete raw records live in `verification.json`; hardware always
remains HW_UNVERIFIED. No synthesis, mapping, PnR, STA, board, frequency or power
evidence is produced by this package.

## Mathematical contract and canonical IDs

Let f[p] be the input pixel at row-major address p. Zero is an ordinary gray
level; there is no background exemption, ROI, quantization, mask or keep input.
For every present gray level l, consider the in-bounds connected components of
`{p: f[p]>=l}`. Connectivity is static4 or8. Outside pixels are excluded, and
horizontal/diagonal neighbors never wrap rows.

A component at level l becomes a canonical tree node precisely when it contains
at least one pixel having f[p]=l. Its canonical ID is the smallest row-major
address among those level-l pixels in that component. Those pixels can connect
through higher pixels, so equal-gray flat-zone labeling alone is insufficient.
The node's area is the number of **all** pixels in this upper-level component,
including its brighter descendants. Its parent is the canonical node at the
largest strictly lower present level that contains it. The unique global root
is the smallest address at the global minimum, covers all N pixels and points
to itself. There are between1 and N canonical nodes.

Exactly N output records appear in raster address order:

|Field|Successful-frame meaning|
|---|---|
|m_index|The original pixel's address p,0..N-1|
|m_parent|For a canonical pixel, the containing lower-level node; otherwise its own-level canonical ID|
|m_level|The exact original value f[p], also for noncanonical pixels|
|m_canonical|One precisely for the canonical representative|
|m_area|The canonical upper-component area, or zero for a noncanonical pixel|
|m_sof/m_eol/m_last|First record, true row end, and final record|
|m_errors/m_tag|Repeated owned-frame status and first accepted tag|

Every parent is canonical. A noncanonical pixel has the same level as its
parent; a nonroot canonical pixel has strictly greater level than its parent.
The root's area is N, including for an all-zero image. A constant image has only
canonical node0, with area N. This is a pixel-expanded canonical tree, not a
dense renumbering of node IDs, and no separate tree-traverser stream is emitted.
All values, areas and ties are exact integers without tolerance or clipping.

## Clock, frame and cancellation

One rising-edge clock, synchronous active-high reset and ordinary ready/valid.
There is no CE, CDC or implicit conversion to a CE-qualified neighboring stream.
Transfer occurs on valid&&ready, with every source field stable while stalled.
Static WIDTH*HEIGHT=N accepted pixels define one complete row-major raster.
SOF must occur exactly at p0; EOL exactly at each actual row end. There is no
input LAST, restart-on-SOF, resynchronization scan or missing-pixel timeout.
The caller supplies the remaining N pixels or resets a partial frame.

The first accepted pixel owns s_tag even if its markers are malformed. Later
tags are ignored. Independent sticky m_errors bit0 is a SOF mismatch and bit1
an EOL mismatch. A framing error does not shorten capture or steal ownership.
After draining the complete frame, errors bypass all histogram/tree work and
emit N records with parent, level, canonical and area zero. Output index and
markers still describe the complete fixed raster; first tag and both errors
repeat. No provisional or partly valid tree escapes before all input validation.

The current frame owns the core through its final output acceptance. Input
cannot overlap processing or a held result. A queued next pixel transfers no
earlier than the following rising edge. All result fields and valid stay stable
under arbitrary backpressure. Successful replay has always-ready II4; an error
raster has II1. These are source-level cycle counts, not video-rate claims.

Reset immediately gates ready, valid and all public markers low; its active
edge cancels capture, sort, traversal, area accumulation or held output and
zeros public/control state. Consumers discard any transferred prefix from an
aborted frame. RAM and its clocked read registers remain unreset. New capture
overwrites every image pixel and clears its active flag; histogram clearing
precedes counting; sort writes every order address once; activation initializes
each private forest/tree/area entry before any owned pointer can read it.
Every new frame thus owns the full reachable data without a bulk RAM reset.

## Architecture and logical budget

|Parameter|Default|Final legal domain|
|---|---:|---|
|WIDTH/HEIGHT|8/8|Each1..16|
|PIXEL_W=B|8|1..8, all input bits used|
|CONNECTIVITY=K|4|4 or8|
|TAG_W|8|1..32|

Let G=2^B, IW=max(1,clog2 N), CW=max(1,clog2(N+1)),
XW=max(1,clog2 WIDTH). CW represents N exactly, including N256. Histogram
counts and inclusive prefix ends are at most N. A sort write uses end-1 only
for a nonempty bin; every address is in0..N-1. Areas are at most N.

Six separate single-port, clocked-read banks hold image `{active,pixel}`,
stable order, private union-find parent, image-tree parent, area and histogram.
Logical RAM is exactly `N*(B+1+3IW+CW)+G*CW`: **3,968 default /13,056 maximum
bits**. Declared scalar/read/output storage is exactly
`15IW+5B+6CW+3XW+TAG_W+14`: **203 default /272 maximum bits**, including unreset
RAM read registers. Combinational neighbor signals are not storage. These
are logical source declarations, not measured FF/LUT/BRAM/DSP or fit results.
Risk is LOW default /MEDIUM maximum because of serial forest work and RAM
packing. No external primitive, ROM, generated coefficient, multiplier, data
divider/modulo, sorting network or parallel image arithmetic array is required.

The selected schedule uses counting sort: clear G bins, count pixels with
separate image read/bin read/bin write, form inclusive prefixes, then scan
pixels backwards and write each at --end[value]. This produces ascending gray
and ascending-index order. Reverse traversal activates pixels by descending
gray and descending index, so a level's final representative is its minimum
raster address. A serial remainder/subtract computes x once per activation;
neighbor addressing is constant-width addition/subtraction with explicit bounds.

An activated pixel initializes itself as the private/root tree node. Each active
neighbor is followed through the private z bank to its current root. Distinct
roots are linked to the newly activated pixel. z is separate from the published
tree. Path halving reads old parent and grandparent on separate clocks and writes
the grandparent back in a later phase, then follows that ancestor. It can never
turn an ancestor into a child or change the represented component. No bank needs
a simultaneous read/write, forwarding or vendor collision mode.

After all activation, ascending order visits parents before children and removes
noncanonical same-level intermediate parents. Descending order then adds each
pixel's initialized unit area to its parent, skipping only the self-root. This
accumulates all members and descendant regions into exact canonical areas.

## Exact work and finite preflight budget

Let R be the sum of all in-bounds directed grid degrees:
`R4=2*HEIGHT*(WIDTH-1)+2*WIDTH*(HEIGHT-1)` and
`R8=R4+4*(WIDTH-1)*(HEIGHT-1)`. Exactly R/2 active-neighbor finds occur, since
each undirected edge is examined once after both endpoints are active. There
are exactly N-1 successful root links because the full rectangular domain is
connected. Let H count actual z-bank reads during these finds. Each read has one
following consume edge, including the two reads/two consumes of a halving step.
Chronologically newer links and ancestor shortcuts give depth<=N, hence
`H<=R*N/2` without assuming any speedup from halving.

Accepted-final-input to first-valid latency for a good frame is exactly

```text
3G + (20+2K)*N + WIDTH*HEIGHT*(HEIGHT-1)/2 + 2R + 2H + 3.
```

This includes CHECK, G clear +3N histogram +2G prefix +3N sort, activation and
coordinate extraction, every neighbor/read/find/link,5N canonicalization,
4N area steps and the first3 replay edges. The resulting whole-domain bound
is17,571 default; maximum C4=257,539 and C8=491,787 edges. Errors take exactly1
edge and no numerical work. Source gaps and output holds are external waits.

Each reset recovery uses a complete fresh raster with only its final pixel
bright. Its tree has root0/area N and bright final node/area1 (a single bright
root for N1). Activation follows descending raster order. Without any halving,
its find reads are bounded by
`H4=HEIGHT*(WIDTH-1)+(HEIGHT-1)*(WIDTH*WIDTH+WIDTH-1)` and
`H8=H4+(HEIGHT-1)*(WIDTH-1)*(2*WIDTH+2)`.
At16x16 these are4305/11955, giving fresh tail bounds20,389/39,537.

Before any HDL, architecture-only work accounting of the three fixed reset
patterns (last bright, first two bright, constant) predicted maximum C8 H3403
or3407 and tail22,433/22,441; C4 H1683/1684 and tail15,145/15,147. This model
was used only to size finite children, not as the numerical result oracle or
as simulation evidence. To leave margin within20 seconds, both N256 profiles
partition their46 predetermined reset IDs into independent even/odd children
of23 each; main images have a separate child. This split predates the first HDL.
All original probes and full fresh frames remain; a timeout cannot cause a new
split, smaller fixture or longer limit.

## Frozen evidence and offline use

The final matrix has10 numeric profiles:
(W,H,B,K,T)=1/1/1/4/1,1/7/8/8/3,7/1/3/4/8,
2/2/2/4/8,2/2/2/8/8,3/3/1/4/8,3/3/1/8/8,8/8/8/4/8,
16/16/8/4/32 and16/16/8/8/32. The first8 have16 directed/error images each;
the2x2 profiles add all256 four-gray images each, and3x3 all512 binary images
each. Both maximum profiles have8 fixed images: constant, full256-gray ascending
and descending ramps, checkerboard, nested levels, seeded full-byte image and
two framing errors. Total1,680 main frames. Full legal geometry, bit width and
both connectivities receive numerical checks, including256-node chains.

The original standard-library Python oracle separately computes connected sets
at every present threshold, chooses the prescribed representatives and nearest
strict containing parents. It certifies reconstruction of every threshold's
component partition, unique root and all canonical areas. It does not activate
sorted pixels, use union-find or imitate RTL phases. Expected output retains
the complete tree/area/level for every input pixel.

The TB checks every result bit, complete source/sink stall stability, actual
next frozen pixel held throughout computation and every result until real
acceptance, II1 capture, exact structural work/latency, each clocked RAM image,
fresh-pointer ownership, order bijection/ties, root-link/depth bounds and root
area N. Reset IDs0..36 target every reachable basic state. IDs37..45 add held
error/final, bad partial capture, coordinate iteration, deep halving, actual
canonical compression, root area, last prefix and last sort write. N1 omits
only impossible neighbor/root/deep/partial contexts; other exclusions follow
explicit geometry. Every target is observed at a falling edge, immediately
reset without an intervening active edge, followed by a complete same-geometry
fresh tree, distinct tag, every-pixel hold, retirement and no-stale check.

`TEST_PLAN.json` freezes all sources,10 fixture hashes, every stimulus hash,
reset/group IDs and45 exact children before the first HDL. The matrix is version,
two syntax checks,10 compiles,10 main simulations,12 reset simulations and10
named parameter rejects. Every compiler/simulator child has a20-second hard
timeout; TIMEOUT is terminal. Ordinary failure requires preserving exact source,
plan, receipt and NOT_RUN tail before an authorized same-stimulus repair.
Existing receipts block automatic reruns. No B20 or inherited tools are rerun.
Read-only review never invokes the runner, oracle, compiler or simulator.

The first attempt stopped at an ordinary TB end-coverage guard after the1x7
reset child completed all45 target/fresh iterations: target Z_HALVE had been
observed at a falling edge and immediately reset, but the state mask counted
only rising edges. `history/attempt_01.json` preserves the exact original19
source/fixture texts and hashes, plan, raw FAIL receipt and9 actual/36 NOT_RUN
child dispositions. The coordinator authorized recording the state at that
existing observation point and an exact selected-target bitmap, with no added
edge or reduced check. Only TB, explicit archived `--run --repair` gate and this
chronology change; all RTL,10 complete fixtures, inputs/results,443 reset targets,
fresh frames,45 children and20-second limits remain identical. Repair does not
regenerate fixtures or invoke the oracle. The original FAIL remains a FAIL.

Owner-only `python run_tests.py --freeze` prepares the matrix; `--run` consumes
it. `files.f` closes production over one local RTL; `example/files.f` adds the
complete default `region_tree8` direct instance. No fixtures, Python, network,
NumPy/scikit-image or sibling RTL are needed to use the production core offline.
Root LICENSE/NOTICE apply to this independently authored implementation; fixed
upstream reading and actual semantic deduplication are in SOURCES.md.
