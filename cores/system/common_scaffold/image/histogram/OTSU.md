# Exact Otsu threshold solver

`img_hist_otsu_threshold` accepts one command, then exactly 256 unsigned bin
counts in ascending gray-level order. COUNT_W supports 1..24 (default 16).
Commands contain no payload; start over only after the response is consumed.
Every transfer requires shared CE and valid/ready. Histogram RAM uses
synchronous reads/writes and is fully overwritten for each new command.

It chooses t maximizing between-class variance for classes [0,t] and [t+1,255].
Let N be total count, S weighted total, w lower-class count, and s lower-class
weighted sum. The criterion, after dropping a common constant, is
`(S*w-s*N)^2 / (w*(N-w))`. Empty classes are skipped. Candidate and current-best
rational scores are compared by exact cross multiplication; no division,
floating point, epsilon test or early score quantization appears in the solver.
Strict improvement selects a new t, so exact ties retain the smallest t.

All-zero histogram returns rsp_error=2 and threshold=0. Nonempty single-level
histograms have no valid two-class split and return threshold=0, rsp_error=0.
Other valid results return rsp_error=0. Response fields stay stable while
stalled or CE paused. Reset cancels partial loading, arithmetic and response;
RAM contents need not reset. The interface does not guess a truncated histogram:
it waits for all 256 counts or reset. Extra counts are not accepted during solve.

Total-count width is COUNT_W+8, weighted-sum width COUNT_W+16. Guarded delta,
squared numerator and denominator widths are derived from these bounds. Wide
products share `img_hist_serial_multiply`, with fixed B_W enabled shift/add
iterations per product. Up to six wide products are needed per valid threshold.
There is no throughput or timing claim; full COUNT_W=24 histogram tests may
take over 100000 enabled cycles to solve. Narrow bin weighting still uses an
8-bit-index multiplication. No synthesis/resource/board result is claimed.

Run `python cores/system/common_scaffold/image/histogram/run_otsu_tests.py` or
`python cores/system/common_scaffold/image/run_groups.py --groups otsu`.
Thirty-two 256-bin histograms across COUNT_W=1/8/16/24 compare against a Python
Fraction oracle using independently expressed class means and between-class
variance. Tests include maxima, sparse/dense/random inputs, ties, empty and
constant histograms, source gaps, CE, stalled responses, load/compute reset.
Source hashes and small logs are retained; temporary fixtures/images are removed.

This is a histogram-to-threshold entry, not a same-frame image binarizer. A
caller supplies a histogram and applies the returned threshold to stored or
subsequent pixels using the desired strictness/inversion convention. Existing
`img_filter_threshold` uses >=; standard Otsu binary output commonly uses >.
A frame wrapper must state and test that choice rather than assume equivalence.

## Same-frame entry

`img_hist_otsu_frame` now provides the complete GRAY8 capture/solve/replay path.
It reuses `img_hist_accumulator` and the exact solver above, and stores the frame
in internal synchronous RAM. Input frames and all histogram bins are fully
overwritten between commands; control reset does not clear RAM contents.
Defaults: FRAME_WIDTH=32, FRAME_HEIGHT=24, COUNT_WIDTH=16, TAG_WIDTH=16.
Supported dimensions are 1..512 each, COUNT_WIDTH=1..24, with total pixels no
greater than 2^COUNT_WIDTH-1. Insufficient count capacity rejects start without
accepting pixels. Dimensions are elaboration parameters, not runtime commands.

On accepted start, start_tag and start_invert latch atomically. The entry then
clears its histogram and accepts exactly width*height pixels. SOF must appear
only on the first pixel; EOL must mark every row end. Malformed markers are
recorded while all expected input pixels drain; that frame emits an error
response and no output. With valid input it computes the threshold from that
same frame, then replays binary `255 if ((gray > threshold) XOR invert) else 0`.
Comparison is strict >, consistent with the solver's [0,t]/[t+1,255] partition.
Output regenerates SOF/EOL/last and retains the command tag; data and markers
hold under CE pause or backpressure. There is one outstanding frame, with no
overlap between capture and replay, and no video-throughput claim.

done_valid is generated only after final output consumption or a detected
error. done_count is accepted pixel count (zero for parameter rejection), and
done_threshold is meaningful during valid output and successful done. Error
codes: 1 invalid parameters/count capacity, 2 frame markers, 4 histogram
overflow, 8 solver failure, 16 internal histogram/tag/read failure. Errors
produce no pixels. The normal parameter bound prevents overflow for a complete
valid frame. busy includes a pending done response; a new frame waits until
that response is consumed. Shared CE applies to all transfers. Reset cancels
capture, histogram transfer, solve, replay and done. A truncated input without
all expected pixels waits for more input or reset; no implicit timeout exists.

Run `python cores/system/common_scaffold/image/histogram/run_otsu_frame_tests.py`
or `python cores/system/common_scaffold/image/run_groups.py --groups otsu_frame`.
Five valid dimensions (1x1, 5x3, 8x8, 7x4 and default 32x24) cover 80 completed
commands including 10 marker errors, 12264 output pixels, both invert modes,
constant/bimodal/gradient/random frames and complete recovery after reset.
A separate invalid 8x8/COUNT_WIDTH6 case verifies parameter rejection. Source
gaps, CE, output/done stalls, tags, input marker validation, reset cancellation
and a fresh zero frame after reset are checked against the Fraction oracle.
No synthesis, timing/resource or board result is claimed.

External design check read on 2026-10-18:
https://github.com/opencv/opencv/blob/4.10.0/modules/imgproc/src/thresh.cpp

Checked its Otsu lower/upper class means and between-class variance scan.
OpenCV uses floating-point class probabilities and an epsilon skip. This RTL
uses exact nonempty-class checks and rational comparison, so very unbalanced
classes need not match OpenCV epsilon behavior. No implementation code is copied.
