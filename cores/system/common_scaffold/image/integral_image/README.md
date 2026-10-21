# Persistent integral tables with arbitrary rectangle queries

`integral_image.sv` stores an entire exact integral image and squared integral
image, including a real zero boundary, then answers arbitrary half-open rectangle
queries from synchronous RAM. Default geometry is 32×24 unsigned RAW12/gray12.
Input widths 8, 10 and 12 are supported. No host-computed integral or external
memory/readback computation substitutes for the hardware recurrence or queries.

This fills a specific missing capability. The repository already has
`cores/system/extended_library/src/img_integral.v`: an 8-bit streaming integral with an
18-bit previous-row storage limit, without square-integral/random queries. It
also already has real `cores/signal_processing/dsp_isp_library/isp/localstats/rtl/integral_stats.sv`:
8/10-bit streaming integral/squared integral and trailing-window local statistics.
That module retains a previous row, not a complete queryable frame. This new
module adds **persistent full tables, arbitrary repeated four-corner queries,
explicit zero boundary, 12-bit support and query/frame isolation**. It does not
claim to be the repository's first integral or squared-integral implementation.

## Exact arithmetic

Table coordinate `(X,Y)` is in `0..WIDTH` and `0..HEIGHT`:

```
SAT[Y,X] = sum(pixel[y,x] for 0 <= y < Y and 0 <= x < X)
SQ[Y,X]  = sum(pixel[y,x]^2 for 0 <= y < Y and 0 <= x < X)
SAT[0,X] = SQ[0,X] = SAT[Y,0] = SQ[Y,0] = 0
```

Start explicitly writes the top zero row. Each input row first writes its zero
column, then accepted pixels update a row-prefix sum and squared row-prefix sum.
The accepted edge reads the previous integral row synchronously; the following
enabled edge writes `previous_row_value + row_prefix`. There are no asynchronous
full-frame register reads. Each table has one shared synchronous read port and
one write port, so row construction and later query traffic reuse the same RAM.

A query is the half-open source rectangle `[x0,x1) × [y0,y1)`. Hardware reads
`A=table[y1,x1]`, `B=table[y1,x0]`, `C=table[y0,x1]`, `D=table[y0,x0]`, then
returns `A-B-C+D` for both tables and `(x1-x0)*(y1-y0)` for count. Empty width
or height is valid and yields exactly zero sum, square sum and count. Reversed
coordinates or endpoints beyond the image produce an error with zero results.
Query `(0,0,X,Y)` exposes any integral-table cell, including every zero-border
cell; query `(x,y,x+1,y+1)` reconstructs a single original sample and its square.

Widths are fixed unsigned `sum32`, `square40`, `count32`. For N<=65536 and
BITS<=12, `N*4095=268369920 < 2^28`, and `N*4095^2=1098974822400 < 2^40`.
The row-prefix bounds are smaller than these full-frame bounds. Input squaring
uses a full `2*BITS` product. Four-corner subtraction may underflow an intermediate
unsigned expression, but modular arithmetic yields the exact final nonnegative
rectangle result, which is within the table width. No saturation/rounding is used.

## Interface and lifetime

Static parameters: `WIDTH=32`, `HEIGHT=24`, `BITS=12`. Width/height must be
1..4096, total pixels <=65536, BITS in {8,10,12}. Geometry is static, so it
cannot change during a frame. Maximum geometry is an arithmetic/interface limit;
it is not a claim that all such complete tables fit Tang on-chip RAM.

| Ports | Meaning |
|---|---|
| `clk,rst_n,ce` | Rising edge, active-low synchronous reset; reset overrides CE |
| `start_valid,start_ready` | Begin a new frame; accepted only idle or with previous valid frame available |
| `abort` | Hold through an enabled edge to invalidate the frame and cancel capture/query/held response |
| `s_data[BITS-1:0],s_valid,s_ready` | Raster input accepted on enabled ready/valid edge |
| `s_sof,s_eol,s_last` | Exact first pixel, line ends and final pixel markers |
| `done_valid,done_ready,done_error,error_code[3:0]` | Held terminal frame result |
| `frame_valid` | Complete table exists; queries become ready after frame DONE acknowledgment |
| `accepted_pixels[31:0]` | Input handshakes since last start, including a faulty marker beat |
| `query_valid,query_ready` | Rectangle request handshake |
| `query_x0,query_y0,query_x1,query_y1[15:0]` | Latched half-open rectangle endpoints |
| `result_valid,result_ready` | Held response handshake |
| `result_sum[31:0],result_sqsum[39:0],result_count[31:0]` | Exact unsigned rectangle statistics |
| `result_error,result_error_code[3:0]` | Response error, independent of successful frame status |

All transfers require `ce && valid && ready` at the rising edge. CE freezes
memory operations, counters, status and held payload. Query fields are captured
at request acceptance and may immediately change afterward. Response payload and
valid hold through backpressure/CE stalls. Abort/reset intentionally cancel a
held response; a consuming client must discard the interrupted frame transaction.
Abort takes effect at an enabled edge, not combinationally while CE is zero.

Frame processing ends in held DONE; `frame_valid` can already be high there,
but neither queries nor a new start are accepted until `done_ready`. After
acknowledgment, any number of queries may be made. A query error leaves the
successful frame intact for subsequent queries. A new start has priority over a
simultaneous query request, invalidates the old table immediately, resets the
accepted count and initializes the new zero boundary. Starts are backpressured
while a query/response is outstanding. Thus no accepted query is silently
reassigned to the next frame. An unbuilt/failed frame never advertises query-ready.

Frame errors: `2` malformed SOF/EOL/LAST, `3` abort, `4` illegal internal state.
Query error: `1` reversed or out-of-bounds rectangle (all result data zero).
Reset clears validity/status even with CE zero; RAM contents are deliberately
not reset. A subsequent healthy frame overwrites the whole table before exposing
it. Abort is honored during initialization/capture/commit, ready/query/response;
it is ignored in idle or terminal DONE. There is no watchdog: a stopped input
source needs abort or reset. Already transferred earlier query results remain
completed results of the earlier frame.

Input II is two enabled cycles. Healthy frame construction after the start edge
uses `(WIDTH+1)+HEIGHT+2*WIDTH*HEIGHT` enabled edges through DONE. Valid rectangle
results take eight enabled edges after request acceptance (four synchronous
read/use pairs); malformed requests produce an immediate held error response.
Queries are serialized. This is a resource-oriented random-access statistics
store, not a strict II=1 live video filter.

## Verification and resources

From repository root:

```
python -B cores/system/common_scaffold/image/integral_image/run_tests.py
python -B cores/system/common_scaffold/image/integral_image/test_protocol.py
python -B cores/system/common_scaffold/image/integral_image/test_numeric_limits.py
python -B cores/system/common_scaffold/image/integral_image/synth_check.py
python -B cores/system/common_scaffold/image/integral_image/freeze.py
```

Main regression passes **28 frames / 9324 rectangle responses** across seven
profiles: 1×1/1×7/7×1, odd and even geometries, all supported bit depths and
default32×24. Every SAT cell is queried and each original pixel reconstructed;
zero/full-maximum/random/patterned frames, full image, border/empty/random/invalid
rectangles, backpressure, random CE, held DONE and consecutive-frame isolation
are checked against independent Python integer cumulative and direct-pixel sums.

The tests also execute **actual `cv2.integral2`** and compare both complete arrays
exactly. Input is converted to float64 to cover unsigned10/12 values; all allowed
square sums are below2^40, safely exact in float64's53-bit significand. No integer
wrap or loose floating tolerance hides errors. Numeric limits additionally reject
seven invalid profiles, prove the arithmetic bounds, and run a true full-maximum
256×256 RAW12 frame plus4096×1 RAW12 and1×4096 RAW10, each with50 RTL queries.
Only the smaller main profiles query every cell; maximum profiles use full-frame,
edge/empty, random and invalid queries and compare the entire software arrays.

Protocol tests add21 healthy recovery frames/full-frame queries,8 abort states,
10 CE-disabled resets including held DONE/response, all3 marker faults after
partial input, counted faulty handshakes and simultaneous start/query arbitration.

Standalone Gowin synthesis with `-nodsp` and `check -assert`:

| Profile | Conservative LUT-class | DSP | Raw BRAM primitive count | Conservative BRAM9 units |
|---|---:|---:|---|---:|
| 32×24 RAW12 | 1633 | 0 | 5 DPX9B | 10 |
| 31×17 RAW10 | 1487 | 0 | 5 DPX9B | 10 |
| 64×32 RAW12 | 1940 | 0 | 12 SDPX9B | 24 |

LUT-class includes LUT/ALU/MUX and4×RAM16SDP4. BRAM9 units conservatively charge
two per mapped DPX9B/SDPX9B primitive. All measured profiles meet15K LUT-class,
4 DSP and46 conservative BRAM9 units. These are isolated synthesis results,
not routed timing, full-system fit or board acceptance.

`fetch_references.py` retrieved actual mature OpenCV scalar/SIMD integral sources
and records URLs, SHA256 and relevant zero-boundary/row-prefix/square recurrences
in `references.json`. No upstream code is copied into RTL. The behavioral
reference is the installed, actually executed OpenCV version recorded per test
profile; downloaded4.x source inspection is not falsely claimed to be that exact
binary version. Every tool run uses TemporaryDirectory, cleaning simulation
images, netlists and downloads. Compact JSON evidence and source hashes remain.
No old core, registry, source list, JTAG, UART or board acceptance file is changed.
