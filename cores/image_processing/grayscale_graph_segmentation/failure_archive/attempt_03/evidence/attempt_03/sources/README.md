# Exact grayscale adaptive graph segmentation

`grayscale_graph_segmentation` consumes actual unsigned8 grayscale pixels and
computes a complete four-neighbor Felzenszwalb–Huttenlocher partition in RTL.
An optional, precisely ordered minimum-component-size pass follows the adaptive
merge pass. No host edges, labels, sorted graph or segmentation result is an input.
Canonical labels and exact areas support region extraction and labeling pipelines.

Current status: **RTL_CANDIDATE / HW_UNVERIFIED**. This is the author draft.
Preparation, oracle assertions, lint and simulation are **NOT_RUN**. Only a
separately approved, matching `SOURCE_SEAL.json` and terminal receipt can qualify
the finite checks. No synthesis, PnR, STA, board, mapped resources, Fmax or power
evidence is produced. Original/inherited numerical matrices and combined checker
are outside this package's execution scope.

## Exact graph and deterministic partition

Let N=WIDTH*HEIGHT and p=y*WIDTH+x. Every in-bounds right edge `(p,p+1)` and
down edge `(p,p+WIDTH)` occurs exactly once. There are
`E=HEIGHT*(WIDTH-1)+WIDTH*(HEIGHT-1)` edges. No diagonal, outside or wrap edge
exists. Its weight is the exact integer absolute grayscale difference0..255.
Zero is an ordinary gray value; every pixel belongs to one region.

The complete graph is ordered lexicographically by `(weight,p,direction)`,
where right has direction0 and down direction1. Invalid boundary directions
are skipped without renumbering pixel addresses. Equal-weight ties therefore
have a fixed observable order.

Initially every pixel is a singleton with size1, internal difference0 and
canonical label p. For each ordered edge of weight w joining distinct A/B,
merge exactly when both of these rational inequalities hold:

```text
w <= Int(A) + K/size(A)
w <= Int(B) + K/size(B)
```

RTL compares `max(0,w-Int(C))*size(C) <= K`, retaining the complete product.
K is unsigned16; comparison width is at least16 even for N=1. New metadata
contains the summed area, minimum original member address, and
`max(Int(A),Int(B),w)`. The regular ordered pass has Int(C)<=w whenever an
edge tests C. There is no float, division, threshold rounding, quantization,
heuristic early termination or iteration cap.

If min_size>1, replay the same complete sorted edge array once. Different
regions merge precisely when either current size is below min_size; the FH
predicate is not applied in this second pass. Sizes never decrease, and the
connected rectangular graph plus min_size<=N gives final size>=min_size.
The final partition includes this stated postprocessing. Claims about the
paper's original adaptive partition apply to the first phase.

The existing K-means assets cluster color vectors around centers; watershed
grows supplied markers; max-tree builds upper-level component hierarchies.
This service discovers spatial regions from adaptive inter-region/internal
edge evidence. See [SOURCES.md](SOURCES.md) for the actual semantic inventory.

## Stream and frame contract

All ports use one rising-edge `clk`, synchronous active-high `rst`, ordinary
valid&&ready handshakes, no CE and no CDC. While rst is high, ready/valid are
gated low; an active reset edge cancels capture, computation and held output.
RAM payloads/read-q do not reset. Control and every bank's valid lifecycle are
re-established before its next read. Consumers discard any pre-reset output
prefix from a canceled frame.

|Input|Meaning on s_valid&&s_ready|
|---|---|
|s_pixel[7:0]|Exact unsigned grayscale sample in row-major raster order|
|s_sof/s_eol/s_last|True only at p=0 / x=WIDTH-1 / p=N-1 respectively|
|s_k[15:0]|Adaptive K0..65535, captured only with the first pixel|
|s_min_size[COUNT_W-1:0]|Minimum area1..N, captured only with first pixel|
|s_tag[TAG_W-1:0]|Opaque first-pixel tag; later tags are ignored|

Sources hold every offered field stable while valid and stalled. Exactly N
accepted samples form a frame. Markers never alter that count or resynchronize
the stream. Missing input can wait indefinitely; reset is required if pixel
count alignment is lost. Later K/min_size/tag changes have no effect.
Capture can accept one pixel per clock. Input ready remains low throughout
computation and output ownership; frames are not overlapped.

Each successful frame emits N final records in original pixel order:

|Output|Meaning with m_valid|
|---|---|
|m_keep|1 for each successful pixel record;0 for the sole error record|
|m_index|Original row-major pixel address|
|m_label|Smallest original pixel address in that final region|
|m_area|Exact final region size, including the current pixel|
|m_regions|Final number of regions, repeated on every successful record|
|m_sof/m_eol/m_last|First record / true row end / final record|
|m_errors[3:0]|Sticky frame error mask; successful frames have0|
|m_tag|First accepted tag, repeated throughout ownership|

Every numeric/marker/tag field is stable while output valid is stalled.
Numerics are meaningful only with valid. A frame starts output only after
all adaptive and minimum-size merges finish; no provisional labels escape.
The next frame can first transfer on the edge after the final record retires.
There is no separate summary handshake. LAST identifies successful completion.
Unbounded source gaps or output backpressure give no unconditional latency.

## Error draining

Errors are ORed across all N accepted input pixels:

|Bit|Cause|
|---|---|
|0|SOF differs from p==0|
|1|EOL differs from the fixed row end|
|2|LAST differs from p==N-1|
|3|First min_size is0 or greater than N|

An invalid frame still consumes exactly N samples, then emits one record with
keep0, index/label/area/regions0, SOF1/EOL0/LAST1, the complete error mask and
the first tag. Segmentation is skipped. No early error output, input-length
reinterpretation, partial successful result or automatic retry occurs.

|Parameter|Default|Legal domain|
|---|---:|---|
|WIDTH|16|1..64|
|HEIGHT|16|1..64; independent of WIDTH, including 1D/non-square frames|
|TAG_W|8|1..32|

`INDEX_W=max(1,clog2(N))`, `COUNT_W=max(1,clog2(N+1))` are derived localparams.
Illegal static parameters cause named elaboration rejection. There are no
runtime dimension changes, external RAM ports, vendor primitives or memory
initialization files.

## Storage, schedule and reuse

Two passes generate the graph directly from captured pixels. The first counts
256 weight buckets; exclusive prefixes replace those counts in-place. The
second identical edge traversal scatters each edge into a single sorted RAM
using incrementing bucket cursors. This is a stable counting sort, with O(E+256)
work and one edge array, rather than256 repeated scans of the complete graph.
Read/modify/write states serialize each histogram update.

The actual unchanged `disjoint_set_union` module is instantiated. Two FINDs
obtain representatives, wrapper metadata decides a merge, UNION commits it,
and its actual returned representative selects the metadata write address.
The wrapper does not predict a winner from pixel order. Rank chooses the winner;
equal rank chooses lower root ID. Canonical minimum-pixel labels are maintained
separately from this physical representative. The external source SHA is bound
in [DEPENDENCIES.json](DEPENDENCIES.json); no inherited tests are rerun.

Five independent synchronous banks hold pixels, sorted edges, bucket cursors,
parent/rank and component metadata. Their payload totals are **21,984 default**
and **406,144 maximum** logical bits. Read-q and all control/state registers
bring those source-declaration totals to **22,426 /406,750 bits**, using default
16x16/T8 and maximum64x64/T32. [COST.md](COST.md) itemizes every bank, index,
read-q and scalar declaration. These are not mapped LUT/FF/BRAM measurements.

The core uses one shared unsigned8xCOUNT_W multiply, addition/subtraction,
comparison and serialized RAM accesses. No division, external memory, ROM table
or unbounded combinational walk is present. Default qualitative structural
risk is LOW; maximum is MEDIUM pending real mapping. The maximum width case is
not a promise of device fit or video rate.

## Fixed preparation and qualification boundary

`AUTHOR_INPUTS.json` freezes the author files and original backend bytes before
numerical preparation. [PREPARATION_PLAN.json](PREPARATION_PLAN.json) allows one
separately approved20-second preparation child. It expands only fixed recipes,
checks eight literal mathematical certificates, stores text/JSON fixtures and
creates `SOURCE_SEAL.json`. No HDL runs during preparation.

After root independently approves the resulting exact source seal and
preparation receipt, [TEST_PLAN.json](TEST_PLAN.json) describes33 children:
one stored-oracle check, one tool version, two lints, six TB compiles,
twelve main simulations, five reset simulations and six named static rejects.
All children are currently NOT_RUN. The compiler's `-Wno-timescale` is fixed
before any execution because the unchanged inherited DSU has no timescale;
all other unexpected compiler diagnostics fail.

The matrix fixes6 profiles:1x1/T1,1x7/T4,6x1/T8,5x3/T8,16x16/T16 and64x64/T32.
Forty-four input frames get two fixed flow-control replays. The two maximum
cases exercise the full8064-entry equal-weight bucket/4096 area, and two2048
pixel halves whose weight255 product must exceed K65535 without truncation.
The plan contains43 actual-predicate reset jobs, each followed by a complete
fresh frame and three reset-high input offers. Four jobs retire one checked
aborted output prefix. Five jobs hold a real next-frame first offer across
cancellation and verify its actual fresh acceptance.

TB checks every output tuple and full sorted graph validity/uniqueness/order,
held fields, final-only output, late-configuration isolation and concrete reset
predicates. The runner rechecks all raw tuple/sort/frame streams against stored
JSON. Reference arithmetic uses explicit component sets and Fraction thresholds;
it shares no RTL parent/rank forest or RAM schedule.

On Windows, a child is created suspended, assigned to a kill-on-close Job Object
without breakaway, then resumed. The20-second deadline includes launch setup;
closing the job terminates its descendants. POSIX uses a new process group.
Cleanup/drain is separately bounded. Each attempt has an exclusive directory,
raw stdout/stderr files, actual argv, hashes and terminal receipt. First failure
or timeout stops, preserving later NOT_RUN slots; there is no automatic retry.
Successful temporary vvp files remain for root hash review and exact cleanup.
HDL/oracle children run from frozen, hash-checked local source/fixture copies
under the attempt's sources directory. The absolute unchanged DSU dependency is
checked before and after each child. Production sources and fixtures are checked
again after each child; copied metadata and exact working directories are recorded.
Root and nested preparation/reports/artifacts/failure_archive/history/evidence
trees, raw streams and vvp text are marked -text before any execution; source
and numerical fixture text use LF. Git normalization must not alter raw evidence.

Commands below are documentation, not permission to execute:

```text
python -B run_tests.py prepare --approved-author-seal <root-approved-AUTHOR_INPUTS-SHA256>
python -B run_tests.py run --approved-source-seal <root-approved-SOURCE_SEAL-SHA256> --approved-preparation-receipt <root-approved-receipt-SHA256>
```

Offline production closure is [files.f](files.f). The full-port16x16 example
and its dependency list are [grayscale_graph16.sv](example/grayscale_graph16.sv)
and [example/files.f](example/files.f). Standalone integration must honor the
ordinary handshake contract; CE-qualified streams require an explicit adapter.
