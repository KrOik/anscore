# Architecture and semantic increment

Existing resident matvec supplies one top-left dense matrix/vector operation;
it does not select distinct input-channel groups or schedule a whole pixel
stream. int4_conv3x3_frame is depthwise per input channel; int4_depthwise3x3_stream
explicitly excludes grouped pointwise convolution. Neither supplies the GxR
transpose needed to mix group order between CNN layers. Production RTL searches
of operator_library/common_scaffold/ip_series found no matching grouped
pointwise/shuffle engine. The new capability is group-local cross-channel
projection and optional channel shuffle over a runtime NHWC pixel stream.

Instantiating one existing dense engine per group duplicates arithmetic and
control. Padding each group into a full dense matrix consumes unused cross-group
weights/MAC cycles. The chosen engine serializes the useful terms of one row,
reuses a single9x4 multiply/40-bit accumulator, and reuses the existing elastic
requantizer. A separate40x17 row scaling multiply has its own registered boundary.
Memory address generation selects a group-local input slice directly. This
differs from a renamed/rewidthed dense block and does not modify its source.

At most1024 terms contribute to a row. Each centered U8 magnitude<=255 and
S4 magnitude<=8, so dot magnitude<=2088960; adding signed32 bias fits40 signed
bits. Product57 is the full40x17 signed result. Sign extension to64 before the
existing RNE quantizer is exact. Its intermediate16-bit saturation cannot change
the final S8 value or clip flag after a legal signed8 zero: an intermediate
value outside S16 stays outside S8 after adding any zero[-128,127]. Offset is
added only after RNE, retaining half-tie parity. Inexact reports shift remainder,
independently of saturation. There is no accumulation wrap or approximate LUT.

Weights are32-bit packed words; metadata61 bits per physical row; input8 bits
per physical channel. Reads are synchronous and consumed in a separate state.
Only config writes weights/metadata and only collection writes the pixel RAM;
neither can overlap compute reads. RAM payload has no reset or initial file.
Validity vectors are resettable and checked before sampling. Physical strides
use static capacities, so reducing a runtime dimension does not change the
meaning of previously configured rows/words. Padding nibbles are never MACed.

Default storage: weights512 +metadata976 +input128 +validity32 =1648 bits,
excluding arithmetic/control/quantizer registers. The maximum allowed G1,
1024 inputs,64 outputs requires282496 bits in those same domains, including
8256 resettable validity bits. Group8,128 inputs,8 outputs is separately legal.
Resource risk MEDIUM at default and HIGH at maximum. There is no external RAM;
BRAM/DSP mapping, occupancy, Fmax and power have not been measured.

With already configured rows, precheck takes G*O*ceil(I/8) active clocks.
Collection can accept a sample every clock. From final pixel-input acceptance
to the first possible output transfer takes2*I+8 clocks; successive row
transfers also take2*I+8 clocks with always-ready sinks. Each subsequent pixel
needs G*I collection clocks plus G*O*(2*I+8) compute/output clocks. These are
source-derived service budgets, not a hardware-rate claim. The single-pixel
buffer trades sustained throughput for bounded storage and one shared MAC.
Arbitrary source/sink stalls remove any wall-clock deadline guarantee.

Finite profiles cover G1/I1/O1/P1/TAG1; G3/I9/O3/P7/TAG8; G8/I128/O8/P4096/TAG32
with separate maximum-pixel and maximum-channel fixtures; and the actual RGB
composition. They include parameter-word boundaries, padding poison, both
orders, unsigned centering extremes, signed coefficients/bias endpoints,
half ties, zero/full scales,31-bit shifts, clipping, held replies/results,
bad shape/index/op, early/missing LAST, reset in compute/output/completion and
reconfiguration/recovery. A G1/I1024/O64 syntax case checks the other extreme.
This finite scope does not simulate every legal parameter combination or a
simultaneous maximum-size dense frame, nor assert learned-model accuracy.
