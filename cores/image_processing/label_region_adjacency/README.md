# Label-image region adjacency with exact contact lengths

`label_region_adjacency` builds an undirected region-adjacency edge list from
a fixed-size label raster. Each positive label denotes one region, even if
its pixels are disconnected. For every two different positive labels sharing
at least one horizontal or vertical cell side, the core emits exactly one
`(m_a,m_b,m_contact_sides)` record, with `m_a<m_b`. The weight is the exact
number of shared unit cell sides. Records are sorted lexicographically by
label pair. No host graph or precomputed contact matrix is supplied.

Label zero is background and is excluded from graph nodes/edges. Diagonal
contact alone creates no edge. Outside-image boundaries create no edge.
Each side is counted once, regardless of input scan direction or which label
is smaller. Multiple disconnected occurrences of the same ID are combined.
The edge list does not enumerate isolated node IDs; the source label image
defines them, and DONE reports their inclusion in the total node count.

This complements the repository's label-generating CCA/watershed and contour
services. It neither relabels connected components nor merges regions. It is
not a binary perimeter/Euler summary or a distance transform. The contact
weight is not an image-gradient mean or a scikit-image `rag_boundary` weight.

## Input, output and completion

All ports share rising-edge `clk`, synchronous active-high `rst`, and ordinary
ready/valid. There is no CE, CDC or runtime configuration. A CE-qualified
neighbor needs an explicit adapter. Every input field must remain stable
until `s_valid && s_ready`. `s_label` is an unsigned integer, with legal IDs
0 through MAX_LABEL. `s_sof` must be true exactly on raster pixel zero and
`s_eol` exactly on the last column of each row. The first accepted pixel's
tag is retained; later tags are ignored.

Exactly WIDTH*HEIGHT handshakes define one raster, left-to-right and then
top-to-bottom. There is **no `s_last` input**. Missing pixels wait indefinitely.
Early/late SOF or EOL marks an error but does not restart, drop a pixel or
change the fixed remaining count. The caller must finish the fixed number
of tokens or reset. An omitted/duplicated pixel cannot be inferred reliably
from marker bits; reset restores alignment if the source loses count.

Capture and contact updates finish before graph output starts. One frame is
in flight. No input is accepted during graph scan, held edge or held DONE.
An edge transfers on `m_valid && m_ready`; all three edge fields and valid
hold through arbitrary stalls. No edge count, first/last marker or tag is
embedded in individual records: the single owned frame and subsequent DONE
delimit the sparse stream. A graph with no edges emits no edge records and
still presents a held DONE result.

DONE transfers on `done_valid && done_ready`. Its complete payload holds
while blocked. Output fields are meaningful only on their respective valid;
some DONE fields are working accumulators during capture/output.

| DONE field | Meaning when `done_errors==0` |
|---|---|
| `done_nodes` | Number of distinct positive labels present, including isolated nodes |
| `done_foreground` | Number of positive-label pixels |
| `done_edges` | Number of transferred unordered graph-pair records |
| `done_contact_sides` | Sum of all edge weights |
| `done_tag` | First accepted pixel's tag |

`done_errors[0]` is a sticky marker error; bit 1 is a sticky input label
greater than MAX_LABEL. The bits are independent and can both be set.
Invalid labels never index either RAM outside its allocation. After any
error, the complete remaining fixed-size raster drains; unnecessary contact
updates stop. The whole frame is rejected: **zero edge records**, and all
four numerical DONE fields are canonically zero. The first tag and error
bits are preserved. No partial graph is published. On successful or rejected
DONE acknowledgement, a new table-clear phase precedes the next raster.

Reset suppresses all ready/valid immediately while high and, at its clock
edge, cancels clearing, partial collection, any RAM update, held edge or DONE.
Public results, coordinates, seen bits and controls reset; RAM is not reset.
Complete table clearing and fresh first-row overwrite precede every RAM use
that could expose prior-frame data. If reset follows transferred graph edges,
the consumer must discard that canceled frame's prefix; there is no rollback.

## Static bounds and storage

| Parameter | Default | Legal values |
|---|---:|---|
| `WIDTH`, `HEIGHT` | 64,64 | Each 1..1024 |
| `LABEL_W` | 4 | 1..8 |
| `MAX_LABEL` | 15 | 1..63 and at most `2^LABEL_W-1` |
| `TAG_W` | 8 | 1..32 |

All dimensions and widths are static. The bounded label budget controls a
quadratic contact table; larger input codes remain representable to report
range errors, rather than aliasing labels. There is no label remapping or
overflow-as-background mode. Illegal configurations fail elaboration using
the named unresolved instance
`label_region_adjacency_invalid_parameters__see_README`.

With `N=WIDTH*HEIGHT`, `K=MAX_LABEL` and `Q=K*(K-1)/2`, derived widths are:

```text
AREA_W = ceil(log2(N+1))
SIDE_W = ceil(log2(2*N+1))
NODE_W = ceil(log2(K+1))
EDGE_W = max(1,ceil(log2(Q+1)))
```

All arithmetic is exact unsigned integer counting, with no fractional scale,
rounding or saturation. Positive pixels are at most N, nodes at most K, and
graph edges at most Q. The total number of possible internal cell sides is
`WIDTH*(HEIGHT-1)+(WIDTH-1)*HEIGHT = 2*N-WIDTH-HEIGHT < 2*N`.
Each pair's count and the accumulated total are bounded by that value, so
SIDE_W includes all intermediate increments. No legal raster wraps a counter.
Maximum widths are AREA_W=21, SIDE_W=22, NODE_W=6 and EDGE_W=11.

One synchronous row RAM stores WIDTH labels. One synchronous single-ported
contact RAM stores K*K SIDE_W-bit counters; only the strict upper triangle
is incremented, and all entries are cleared before capture. A K+1-bit vector
tracks distinct IDs. Memory content is not reset by an array loop. Default
logical RAM storage is `64*4 + 225*14 = 3406` bits, plus scalar registers and
16 seen bits. Maximum logical RAM storage is `1024*8 + 3969*22 = 95510` bits,
plus scalar registers and 64 seen bits. There is no full-frame buffer,
external memory, queue, coefficient ROM or external IP dependency.

## Access schedule and service

On input acceptance, the old row value is synchronously read and the new
label is registered. The left comparison optionally performs a contact-RAM
read then write; the upper comparison does the same. Both contacts may refer
to the same pair, and the second read follows the first write, retaining both
increments. Only after the upper value is consumed is the new row label
written. First-row upper values are explicitly ignored, and left state is
zero at every row start. Reads and writes occupy distinct states, so no
RAM read-during-write collision mode is assumed.

The table address is `(a-1)*K+(b-1)` for sorted labels a<b. Constant-stride
shift/add logic forms this address; no runtime multiplier or divider is
used. The sparse-output scanner reads every cell in the K*K allocation,
including zero diagonal/lower cells, and emits only nonzero counts.

Let `T=K*K` and c be the number of counted contacts on a particular accepted
pixel (0,1 or 2). Its minimum input-to-next-input interval is **`4+2*c`** clocks.
Rejected drain pixels take four clocks each. Clearing takes T clocks before
input ready; after DONE transfer, earliest next-frame input is T+1 periods
later. Capture, graph output and clearing do not overlap.

For a successful frame, let c refer to its final pixel, and j be the table
address of its first nonzero edge. From the final input edge:

| Event | Periods |
|---|---:|
| First edge valid, if any | `6+2*c+2*j` |
| DONE valid for a zero-edge graph | `4+2*c+2*T` |
| DONE valid for a rejected frame | 4 |

After transferring a record at address j, the next record at address k>j
becomes valid after `2*(k-j)` periods. After the final record transfer,
DONE becomes valid after `2*(T-1-j)` periods. The final table cell is always
diagonal and zero. Earliest transfer is one edge after each valid assertion.
These exact controller schedules are checked by the finite TB. Source gaps
and edge/DONE stalls extend completion without an unconditional deadline.
No video-rate, measured frequency or power claim is made.

The selected architecture uses O(WIDTH+K*K) storage and serial RAM operations
to avoid parallel multiport contact updates or an entire label frame. Expected
paths are label comparison/address shift-add, contact increment and scan-zero
detection. Qualitative resource risk is **LOW** at default and **MEDIUM** at
maximum from RAM size, depth and mapping granularity. LUT/FF/BRAM/DSP mapping,
device fit and timing are unmeasured. No synthesis, PnR, STA or board test ran.

## Offline example and finite evidence

`files.f` is the entire production closure relative to this package root.
`example/files.f` adds `segmentation_graph.sv`, a default 64x64/label4 wrapper
that exposes every edge and DONE field. It expects an already labeled raster;
it does not implicitly connect CE-qualified CCA output. No download or code
generator is needed for production use.

```text
iverilog -g2012 -Wall -tnull -s label_region_adjacency -f files.f
iverilog -g2012 -Wall -tnull -s segmentation_graph -f example/files.f
```

From the repository root:

```text
python -B cores/image_processing/label_region_adjacency/run_tests.py
```

The runner uses standard-library Python and existing Icarus/vvp, preferring
the local OSS CAD Suite. Every subprocess has a 20-second limit. Generated
vectors and binaries use a cleaned task temporary directory. Diagnostics on
positive checks fail; illegal-parameter checks require the intended marker.
Failures replace any prior PASS report. Nine source/document SHA256 values,
vector hashes, root LICENSE/NOTICE hashes, exact manifest closure and UTF8/LF
checks bind the report to this package. There are no sibling RTL dependencies.

The independent oracle builds each positive region's boundary by XOR of its
unit-cell side sets, then intersects the boundary sets for each label pair.
It does not follow the RTL's left/up traversal, RAM recurrence or pair index.
Outside sides have no other positive-region partner; equal-label internal
sides cancel. Every edge, order, weight, DONE field and stated latency is
checked. Sender fields change after acceptance and are checked stable during
real stalls. Edges and zero/nonzero-graph DONE results are held for multiple
clocks; frames replay without reset.

Eight profiles are 1x1/K1/L1, 1x7/K3/L2, 7x1/K3/L3, 2x2/K3/L2,
3x3/K2/L2, default 64x64/K15/L4, 1024x1/K63/L8 and 1x1024/K63/L8.
The 2x2 profile exhausts all 256 four-label rasters including background;
3x3 exhausts all 512 assignments of two positive labels. Fixtures include
all-zero/single-label frames, stripes, checkerboards, background separation,
isolated regions, rings, repeated IDs, seeded random labels, early/late marker
positions, illegal IDs and independent/combined errors. Maximum 1024x1024
geometry is syntax compiled; it is not represented as a full-frame simulation.

Immediate reset probes cover every reachable parent state: mid-clear with a
pending input, partial capture, both contact read/write phases, row finalization,
frame finalization, table scan/load, held edge and held DONE with next input
offered. Unreachable contact directions/edge states for thin or single-label
profiles are explicitly omitted. Each canceled phase is followed by a full,
independently checked empty raster. No active edge intervenes after the target
is observed. Twelve illegal configurations are compile-rejected. These finite
probes do not prove arbitrary-cycle correctness over all supported geometries.

After the recorded checks pass, maturity is **LINT_PASS + UNIT_SIM_PASS**;
the example is **INTEGRATION_CANDIDATE**, and all new RTL is **HW_UNVERIFIED**.
No expanded regression or physical tools are run. The source/license preflight
and semantic distinctions are recorded in [SOURCES.md](SOURCES.md).
