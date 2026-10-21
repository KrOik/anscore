# Binary connected-component labeling

`img_connected_components.v` implements actual 4- or 8-connected flood fill for a
binary grayscale frame, then emits a raster label image and per-component area /
bounding box statistics. Repository source search found no equivalent production
component-labeling module. This is a serial buffered engine, not a one-pixel-per-
clock streaming union/find architecture.

## Parameters and interfaces

Compile-time parameters: `WIDTH,HEIGHT=1..4096`, `CONNECTIVITY=4` or `8`,
`LABEL_BITS=1..16`, `MAX_LABELS=1..(2^LABEL_BITS-1)`. Default geometry is 8x8,
8-connectivity, 8-bit labels with capacity 255. Resource availability further
limits practical geometry. Invalid parameter combinations fail elaboration.

Input is binary `s_data`, `s_valid/s_ready`, `s_sof` on the first pixel and `s_eol`
on each true raster row end. Nonzero is foreground; each input is already one bit,
so thresholding belongs upstream. The complete frame is captured before labeling.

Output `m_label[LABEL_BITS-1:0]`, `m_valid/m_ready`, `m_sof/m_eol` contains exactly
WIDTH*HEIGHT samples on success. Label zero is background. Foreground component
labels are nonzero and dense from 1; component identity/partition is the contract,
not a numbering portable across future implementations.

After the full label raster transfers, `stats_valid/stats_ready` emits one record
per nonzero label: `stats_label`, unsigned 32-bit `stats_area`, unsigned 16-bit
`stats_xmin/stats_xmax/stats_ymin/stats_ymax`. Coordinates are zero-based with
inclusive bounds. An all-zero frame emits a zero label image and no stats records.

Finally, `done_valid/done_ready` indicates frame completion with stable
`done_error/error_code[1:0]`. No new frame is accepted until this completion is
consumed. Output order is therefore label image, stats records, then completion.

All transfers are rising-edge `clk_en && valid && ready`. Ready goes low while CE
is disabled, reset asserted or labeling/output is in progress. Output valid and
payload remain stable under backpressure or CE pauses; consumers use the same
CE-qualified convention. Inputs must remain stable until accepted.

## Algorithm and memory architecture

1. Capture frame bits and clear each corresponding label to zero.
2. Scan raster coordinates for an unlabelled foreground seed. Allocate a new
   nonzero label, mark the seed and enqueue its coordinate.
3. Pop coordinates and visit their four axial neighbors, plus four diagonals for
   8-connectivity. An inside, foreground, unlabelled neighbor is marked **before**
   enqueueing, preventing duplicate queue entries. Accumulate area and min/max XY.
4. When the queue empties, store the completed component record and resume seed
   scanning. Once every pixel has been scanned, emit label raster and records.

All frame, label, coordinate-queue and statistics memories use clocked synchronous
read ports and no RAM reset. Old contents are not exposed: frame/label storage is
overwritten in a complete new capture, and queue/stats entries are read only after
being written for the current frame. Constant-width row addressing is explicit
shift/add and consumes no DSP multipliers.

For N=WIDTH*HEIGHT, logical storage is approximately:

- N bits of source mask plus N*LABEL_BITS label bits;
- N*(max(1,ceil(log2 WIDTH))+max(1,ceil(log2 HEIGHT))) queue bits;
- 96*MAX_LABELS statistics bits (area32 + four coordinates16).

One component can contain all N pixels, so the queue is sized N, even if label
capacity is small. Queue storage is reused after each component. Hardware BRAM
packing/port geometry can require more physical bits than these logical totals.
The engine is linear in pixel count and neighbor visits, but serial: capture is
up to 1 pixel per enabled edge; each seed scan takes about 3 enabled edges, each
queued pixel has 3 queue-control edges and up to 3 edges per in-bounds neighbor
(one for each out-of-bounds neighbor). Label emission takes 2 enabled edges/sample,
and stats 2 edges/record before stalls. Typical throughput is tens of enabled
edges per foreground pixel, with full-frame latency; there is no overlap between
capture and output frames. This trades throughput for a clear bounded implementation.

## Capacity, bad-frame recovery and reset

| error_code | Meaning |
| --- | --- |
| 0 | Successful frame |
| 1 | SOF/EOL markers disagree with expected raster coordinates |
| 2 | A new component would exceed MAX_LABELS |
| 3 | Defensive queue-capacity guard triggered |

A capacity error never wraps/aliases labels: processing aborts before allocating
the excess label. All analysis finishes before output starts, so marker/capacity/
queue errors produce no partial label image or stats. Error completion blocks
input until consumed; then the engine waits for a fresh SOF and discards preceding
non-SOF samples. A bad sample that raised the marker error is dropped, including
an unexpected SOF; the caller must submit a new complete frame after completion.
At initial power-up the same SOF resynchronization rule applies without error.
The queue guard is defensive; with marking-before-enqueue and capacity N it is
not expected to occur in valid operation and is not a fault-injection claim.

Asynchronous low `rst_n` cancels capture, analysis, label/stat output or completion,
clears control and returns to SOF synchronization. RAM is not cleared. Output
consumers must discard a partially received frame if system reset occurs; there
is no transaction rollback or frame ID channel. No input-frame timeout is included.

## Reproduce and evidence

From repository root:

```powershell
python -B cores/system/common_scaffold/image/connected_components/run_tests.py
```

The Python reference independently uses software flood fill. It verifies a
bidirectional mapping between reference and RTL labels, proving the same partition
without relying on numbering, then checks every reported area and inclusive bbox.
Six profiles cover 1x1,5x5,9x7 geometry and both connectivities. Each has 17 frames:
all-zero/all-one, diagonal, checkerboard, multi-branch bridge connectivity, exact
label capacity and one more, plus ten random masks at multiple densities. Total
102 reference frames include 9 expected explicit capacity-error frames. Label and
stats stability, random CE/source/sink pauses, completion backpressure, malformed
markers/recovery, and reset during capture, analysis, label output and stats output
are also tested. Final evidence is `test_result.json`; temporary simulation vectors
and executables are removed automatically. Stats/layout tests are executable and
do not depend on a board or camera.

With OSS CAD Suite bin/lib on PATH:

```powershell
yosys -Q -T -p "read_verilog cores/system/common_scaffold/image/connected_components/img_connected_components.v; chparam -set WIDTH 9 -set HEIGHT 7 -set LABEL_BITS 4 -set MAX_LABELS 7 -set CONNECTIVITY 8 img_connected_components; synth_gowin -top img_connected_components -noalu -nolutram; stat"
```

Current isolated mapping: 434 LUT1..4, 40 MUX2_LUT5 + 1 MUX2_LUT6, 177 FF,
5 RAM primitives (1 DPB, 1 DPX9B, 3 SDPX9B), 0 DSP; CHECK reports 0 problems.
See retained `synthesis.log`. This is the specified 9x7 configuration, not a device
fit promise for large frames. No placement/routing, clock/setup/hold signoff,
JTAG or physical input validation was performed. Parent task owns shared
manifest/runner integration; existing accepted IP sources were not modified.
