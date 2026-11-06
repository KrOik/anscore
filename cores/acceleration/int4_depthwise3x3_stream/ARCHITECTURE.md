# Architecture and bounded verification

All stored input is channel-interleaved. A row address increases on each scalar
and returns to zero at the configured row boundary, so runtime channel count
defines row stride. Two8-bit synchronous single-port row memories are read in
parallel on source acceptance. The next cycle captures old row samples and the
72-bit window while issuing row1=new sample, row2=old row1. A third cycle checks
both write acknowledgments. Histories keep two preceding columns of each of
three rows for each channel. The first two freshly received rows/columns mask
all stale data; width/channel changes and reset require no RAM clearing.

At x>=2,y>=2, coefficient word0 and metadata are read together, then word1.
Nine serial9x4 products feed a signed33 accumulator. A product lies in
[-2040,2040]; adding nine to any signed32 bias fits signed33 exactly. A separate
33x17 signed scale stage yields signed50, sign-extended64 for the unchanged
three-stage RNE quantizer. Its signed16 saturation plus signed8 offset followed
by signed8 clamp preserves the specified final result: anything outside16 bits
remains outside8 after an offset of at most128. Inexact and clipping are distinct.
The MAC and scale expression are distinct operators; no unsupported claim that
they map to one physical DSP is made.

RAM request/response CE is tied high, response ready is constant one, and each
single-cycle response is checked in the immediately following state. Reads are
read-first, writes return old data that is ignored after checking acknowledgment.
All index guards precede truncation. Configuration request fields are registered
until acknowledgment; validity commits only after a successful response. Payload
RAM has no reset loop, and no full-frame or vendor-specific storage is required.

Default logical storage: row RAM4096 bits, packed kernels256 bits, padded
metadata256 bits, horizontal history192 bits, validity12 bits; plus72-bit window,
arithmetic and control registers. At maxima row RAM262144 bits, kernels1024 bits,
metadata1024 bits, histories768 bits, validity48 bits. Default resource risk is
MEDIUM (serial throughput and inferred packing); maximum row-memory risk HIGH.
DSP count, BRAM mapping, LUT/FF usage, Fmax and power are unmeasured.

With no stalls, non-window scalars transfer at most once per3 clocks. A window
scalar adds3 kernel-access cycles,9 MAC cycles,1 scale cycle, quantizer issue/
pipeline/wait and one held output transfer before the next scalar. Preflight,
row fill and wrapper serialization/packing also cost cycles. This is a low-area
serialized inference building block, with no promised continuous sample rate.
Arbitrary source/output/configuration/completion stalls impose no deadline.
Maximum external output count1022*1022*16=16711744 fits32 bits.

Planned finite profiles: C1/3x3/T1, C3/7x5/T8, C16/3x3/T32, C1/1024x3/T8,
and real RGB wrapper3/5x4/T8. Each has6 full-image oracle cases: identity center,
mixed signed taps, positive/negative exact half ties with odd offsets, marker
error, signed32 bias/U16-scale extremes, and zero scale. Geometry/channel stride
changes between cases. Files contain independent full-tensor expected results;
file counts and runtime counters are explicitly different domains. Timestamps
do not contribute numerical input.

The TB checks source gaps, output stalls/stability, held config/DONE, invalid
full-width aliases/opcode, missing kernel word, true acceptance of a distinct
future tagged invalid command after DONE, four live reset phases and actual
post-reset recovery. Compile profiles are finite and isolated; maximal all-axis
functional simulation, arbitrary fault injection, whole-network inference,
inherited regressions and hardware checks are outside this qualification.

No oracle has been run during planning. Each of5 archived preparation children
is independent, with6 tensor evaluations; no historical model/runner is imported
or executed. Then3 syntax plus5 compile/simulation pairs run, each20s with5s tree
kill and2s drain. First missing/failed/timed-out child stops further launches.
One exclusive guard prevents automatic repetition; input/tool hashes, plans,
raw stdout/stderr and compiled image hashes are retained. Images stay outside Git.
