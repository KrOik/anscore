# Adaptive local mean threshold

`img_filter_adaptive_mean3x3` fills the local-statistic gap in fixed-threshold
`img_filter_threshold`. It accepts an external row-major 3x3 unsigned window;
top-left is in the least-significant PIXEL_W bits, center at tap 4. PIXEL_W is
1..16. Signed cfg_offset has PIXEL_W+1 bits; cfg_invert is one bit.

The binary selection is `(center > exact_mean(window) - cfg_offset) XOR invert`.
Output is zero or all PIXEL_W bits set. Positive offset makes selection easier;
negative offset makes it harder. Uniform windows with offset zero select false
before inversion. Comparison is strict and uses the exact rational mean,
implemented as `9*center > sum(window)-9*offset`. Neither integer division nor
threshold clipping is performed. Signed guard width covers both offset extremes.

Data, config and sof/eol markers are sampled on accepted windows and advance
through a three-stage elastic output register. Transfer requires shared CE and
valid/ready. CE pause and output backpressure retain data and markers. Reset
cancels pending windows. The external window generator owns line buffers and
border policy; this entry does not pretend to provide full-frame storage.
Use existing `window/` modules to supply aligned windows.

Run `python cores/system/common_scaffold/image/filters/run_adaptive_tests.py`, or
`python cores/system/common_scaffold/image/run_groups.py --groups adaptive`.
Tests compare 850 windows per mode at each of 1/8/12/16 bits to a Python Fraction oracle,
including constant/extreme inputs, signed offset bounds, inverse output,
configuration changes after acceptance, markers, CE, backpressure and reset.
Evidence is logged with source hashes; temporary fixtures/images are removed.
No synthesis, timing, resource or board result is claimed for this new entry.
Otsu is now implemented separately in `../histogram/OTSU.md`.

## Gaussian-weighted branch

`img_filter_adaptive_gaussian3x3` has the same ports and three-stage elastic
output protocol. Its fixed separable weights are `[1,2,1]` horizontally and
vertically, giving matrix `[1,2,1; 2,4,2; 1,2,1]/16`.
Selection is `center > weighted_sum/16 - signed_offset`, then XOR invert.
The RTL compares `16*center > weighted_sum - 16*offset`, with no rounded mean,
no divider and no general multiplier. Width guards include both signed-offset
extremes. Sigma, larger windows and border generation are not implicit features.

The shared regression retains the original 650 mean test windows and adds 200
near-threshold/small-offset windows per width, then runs both mean and Gaussian
against independently expressed Fraction means. Total: 3400 windows per mode,
6800 checks combined, including signed limits, tie/strict comparison, invert,
accepted-configuration capture, markers, CE, stalls and reset cancellation.
No synthesis/timing/resource/board result is claimed for either new kernel.

External design check, read 2026-10-18:
https://github.com/opencv/opencv/blob/4.10.0/modules/imgproc/src/thresh.cpp

OpenCV's adaptiveThreshold uses a normalized box filter for MEAN_C and
subsequently quantizes mean/delta. This RTL uses exact rational comparison and
an integer signed offset; it does not claim bit-identical OpenCV rounding.
Its borders are external rather than implicitly BORDER_REPLICATE. No OpenCV
implementation code was copied.

Gaussian preset checked on 2026-10-18:
https://github.com/opencv/opencv/blob/4.10.0/modules/imgproc/src/smooth.dispatch.cpp

The sigma<=0 3-element preset is [0.25,0.5,0.25], matching this fixed 3x3
separable weight pattern. The comparison still deliberately uses exact rational
means, so it does not claim OpenCV's quantized-output rounding equivalence.

## Pixel-stream frame frontend

`pipelines/img_adaptive_threshold_frame.v` accepts ordinary pixels rather than
external windows. It instantiates `img_window3x3_valid_draft` with two synchronous
line memories and exactly one threshold branch selected by elaboration-time
GAUSSIAN=0 (mean) or 1 (fixed Gaussian). No second arithmetic branch or full
frame buffer is instantiated. Defaults: PIXEL_W=8, MAX_WIDTH=1920, TAG_W=16.

Accepted cfg_valid latches width, height, signed offset, invert and tag. Legal
dimensions are 3..MAX_WIDTH horizontally and 3..65535 vertically, with
3 <= MAX_WIDTH <= 65535. Output crops one pixel from each edge, producing
(width-2)*(height-2) pixels, with regenerated SOF/EOL/EOF and retained tag.
out_width/out_height reflect the cropped size. No border replication is added.
The inherited window scheduler uses at least two enabled beats per input;
output backpressure propagates through the elastic threshold pipeline to input.
Shared CE applies to all transfers; configuration changes after acceptance have
no effect on the active frame.

rsp_valid waits for both window completion and final filtered output transfer.
rsp_pixels reports emitted pixels. Error 0 is success; 1 rejects bad dimensions
without accepting pixels and returns zero output dimensions/count; 2 reports
bad input SOF/EOL after the full expected frame drains. This streaming path can
already have emitted pixels when marker error is reported; those outputs are
not silently retracted. The caller must discard that frame on error response.
Unexpected fatal window errors cancel pending pipeline work via local reset
and preserve the emitted count. Reset cancels work/response; new frames warm
the line buffers before publishing windows. A truncated source waits for the
remaining pixels or reset; no timeout is implicit. New cfg waits until response
consumption, so output tags cannot mix across frames.

Run `python cores/system/common_scaffold/image/pipelines/run_adaptive_frame_tests.py`
or `python cores/system/common_scaffold/image/run_groups.py --groups adaptive_frame`.
Two modes at PIXEL_W1/8/12/16 pass 112 completed commands and 1064 output pixels,
including 24 rejected dimensions and 16 marker-error frames. Tests cover minimum
3x3, one-row/one-column output, changing dimensions between frames, signed bias,
invert, configuration/tag retention, CE/stalls and a fresh zero frame after
partial capture reset. No synthesis, timing/resource or board result is claimed.
