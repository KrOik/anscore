# B41 architecture and semantic selection

Baseline 31a83135a22f845d85840524986895217567625c. Independent new capability:
collapse a multichannel spatial tensor to channel means with one final exact
rounding and directly feed the existing quantized dense stage.

Actual-source deduplication examined cnn_systolic/src/max_pool2d.v: CE-qualified
parallel unsigned maximum, not mean or persistent per-channel spatial reduction;
int4_conv3x3_frame: one-input-channel valid cross-correlation, explicitly no
pooling; int4_weight_matvec: one cached vector times resident weights;
signed8_layer_norm: normalization across a vector, not spatial per-channel mean;
quantized_residual_add: pairwise affine sum with one rounding, no spatial state.
statistics_stream and stream_integer_moments compute scalar block statistics,
not interleaved tensor-to-vector sequencing. Scoped all-core actual RTL/README
search found no global_average/avgpool/adaptive pooling implementation.

Exact signed24 bound: N<=65536, -128*N>=-8388608, 127*N<=8323072. Magnitude is
unsigned24; the minimum sum's magnitude 8388608 fits. Quotient<=128. RNE is
computed by magnitude quotient/remainder and restored sign; the Python oracle
independently uses floor divmod on signed sums. No intermediate saturation or
rounding. Counter inputs24 holds maximum4194304 transfers. Pixel count17
represents65536, channel count16 exposes runtime errors without truncation.

Alternatives: whole-frame RAM wastes storage for a reduction; parallel channel
adders cost64 datapaths; asynchronous sum reads offer II1 but add a wide indexed
combinational mux and inference uncertainty. Chosen one sync RAM port+one24-bit
adder at II2, one24-bit reused restoring divider across channels. Source sum
storage is24*C bits:384 default/1536 maximum, plus control/child registers; no
per-pixel RAM, array-wide reset or multiplier in the core. First pixel avoids
RAM reads and initializes sums; sequential ownership prevents same-edge read/
write collision. The 2-class example adds unchanged matvec's storage, signed9x4
MAC and signed40x17 scale multiplier. No vendor primitive or unknown memory.

Architecture risk LOW for core; MEDIUM for composed mapping of existing matvec.
Inference, LUT/FF/DSP count, clock, power and physical placement are unmeasured.
Default is deliberately small, with bounded maximum channel state.

Finite qualification: syntax default, maximum and actual example; four isolated
compile/sim profiles (1channel/1pixel/tag1,5/31/tag8,64/65536/tag32,4/67/example).
The maximum profile runs65536pixels with1channel and64channels with1pixel, not
the full4194304-sample product. Directed extrema, positive/negative ties,
nondivisible sums, dimensions, early/missing LAST, channel ordering, arbitrary
output and response stalls, source gaps, II2 checks and five reset cut points
with future-frame checks. Model/runner are read before any HDL execution;
all exact inputs and raw logs retained. No automatic retry on any failed child.
