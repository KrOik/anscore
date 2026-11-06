# Architecture before qualification

The task is a reusable learned decoder layer: runtime NHWC U8 feature vectors
map to four spatial phases of signed8 output channels. Direct interpolation
cannot implement learned channel mixing. Reusing the four-layer gray16/Q8
super-resolution adapter would require whole-frame hidden maps and a different
model/CE contract. This layer instead reuses the existing resident INT4 matrix.

For each input pixel, rows `(2*dy+dx)*Cout+c` encode a 1x1 channel map. The first
two phases form the upper output row and transfer directly from the matrix's
held quantizer output. The lower phases write a single synchronous 10-bit row
RAM (data, clip, inexact). After the last source pixel in a row, this RAM replays
in NHWC order, one synchronous read and one held send per sample. Capture and
replay are mutually exclusive. A new input row cannot overwrite unretired data.

There is one matrix invocation per pixel. It rechecks each used packed word,
loads Cin bytes, uses one9x4 MAC over each of4*Cout rows and its existing40x17
row scaler/RNE pipeline. No second arithmetic engine or multiplier is added.
Matrix accumulation40/product57 and scale64 are exact over Cin<=64, signed32
bias, S4 weights, U8 activation/zero and unsigned16 scale. Output8 clamp and RNE
are unchanged; two numerical flags travel through the row RAM unchanged.

Lower-row logical memory is `2*MAX_WIDTH*MAX_OUT_CHANNELS*10`:5120bits default,
327680bits maximum. Packed matrix weights are512/16384bits default/maximum;
vector64/512bits, row metadata976/3904bits, validity32/576bits. Default matrix
MAX_ROWS16/MAX_COLS8; maximum64/64. Payload RAM is never reset. Row/control and
matrix valid bits prevent reading stale values. Resource risk MEDIUM by default,
HIGH at maximum lower-row storage; actual packing, timing and power unmeasured.

For always-ready service, matrix precheck is `4*Cout*ceil(Cin/8)` clocks per
pixel. After its final input at E, the first matrix output can transfer at
E+2*Cin+6, then every2*Cin+3 clocks. Bottom beats only perform a RAM write;
top beats may stall. A lower row costs exactly two clocks per retired sample,
thus4*W*Cout clocks absent downstream stalls. START/FEED and source gaps add
work. This is a serialized layer with burst output, not sustained pixel II1.
These cycle statements derive from source and are not frequency/FPS measurements.

The output shape is2H by2W byCout. Both maximal accepted input and output counts
are67108864 and fit32-bit counters. Child structural inconsistencies and marker
failures flush matrix validity; no hardware or frame rollback is provided.
