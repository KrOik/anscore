# INT4 3x3 stride2 transposed convolution

An NHWC asymmetric U8 input and runtime signed INT4 3x3 kernel produce a signed8
feature map of shape `(2*H+1, 2*W+1, Cout)`. There is no padding, dilation, group
partition or output padding. The mathematical operation is full scatter-add:

`A[2*y+ky,2*x+kx,o] += (X[y,x,i]-x_zero)*K[ky,kx,i,o]`.

Start every output accumulator with signed32 bias, then return
`sat8(RNE(A*U16(scale)/2^shift)+S8(zero))`. RNE occurs before adding zero,
including negative ties; clip and inexact are separate flags. All intermediate
arithmetic is exact over the documented domain. This is an inference layer;
no model, training, accuracy claim or model exporter is bundled.

The implementation actually reuses the unchanged `int4_subpixel_upsample2x`,
`int4_weight_matvec` and `stream_requantize`. Two input row banks assemble a
four-neighbour vector for every anchor, including one appended zero row/column.
The child emits four learned phases in raster order; the final odd column and
row are discarded to leave the full 3x3 transpose shape. Spatial overlap across
both axes distinguishes this from a pointwise subpixel projection.

One clock, synchronous active-high reset, no CE or CDC. Ordinary valid/ready
handshakes apply throughout. An owner holds blocked data/markers; output and
completion remain stable under stalls. Reset cancels in-flight work and
invalidates model configuration, without resetting row RAM payloads. There is
one frame in flight, including held completion.

Static limits: Cin1..16 (default4), Cout1..16 (default4), W/H1..1023
(default64), TAG1..32 (default16). Bad static values elaborate a named missing
module. Runtime nonzero fields are checked at their full16-bit width before
any geometry/channel expansion. Command acceptance snapshots geometry, input
zero and tag; public input is ordered y,x,channel. SOF is set only on the first
scalar; EOL on the final channel of the final pixel of each row; LAST on the
final scalar. The first output cannot precede capture of the complete first
source row. Row capture waits until the child requests its next anchor vector,
after retiring the preceding anchor row's output. This fence prevents a bad
new input marker from cancelling an already offered, stalled output.

Configuration passes through only while idle. `c_op0` writes eight signed4
weights per32-bit word, low nibble first. `c_op1` writes bias/scale/shift/zero
for a matrix row. `c_op2` invalidates all words/metadata;3 returns error2. Range
errors return1; success0. A held configuration response blocks a new frame;
configuration wins a simultaneous offer. Every used word and metadata row must
be configured, including explicit zero weights. Normal frames retain weights.

For runtime Cin, vector columns are `g*Cin+i` for groups current, left, upper,
upper-left (g0..3). Matrix row is `(2*dy+dx)*Cout+o`. To implement K exactly,
load this phase table; each entry is a Cin-length input-channel weight vector:

| Phase dy,dx | Current | Left | Upper | Upper-left |
| --- | --- | --- | --- | --- |
| 0,0 | K[0,0] | K[0,2] | K[2,0] | K[2,2] |
| 0,1 | K[0,1] | 0 | K[2,1] | 0 |
| 1,0 | K[1,0] | K[1,2] | 0 | 0 |
| 1,1 | K[1,1] | 0 | 0 | 0 |

Duplicate each output channel's quantization metadata across its four phase
rows. The interface also allows arbitrary independent phase matrices/metadata;
those implement the specified four-neighbour phase map and must not be called
a shared-kernel transposed convolution. Changing runtime Cin/Cout changes this
packing, requiring a correspondingly configured model. Padding uses x_zero,
so its centered value is exactly zero, including at the extra anchor row/column.

Public outputs are y,x,channel with0-based coordinates. Markers describe the
cropped `(2H+1)*(2W+1)` raster. The child must still drain its cropped tokens
before public completion. rsp_error:0 success,1 invalid runtime geometry,
2 missing model configuration,3 wrong accepted input marker,4 child/internal
failure. Initial model precheck precedes input-row acceptance; there is no
implicit source drain. Stop the failed input frame when completion
arrives. Errors3/4 flush model validity;1/2 preserve it. All outputs remain
provisional until successful completion; discard any partial failed frame.
rsp_inputs counts accepted public scalars including a bad-marker sample;
rsp_outputs counts retired public outputs only. Both fit32 bits at all maxima.

The RGB example serializes RGB24 into three NHWC channels and packs three
output channels. Display bytes encode signed feature+128 (xor sign bit),
without claiming color fidelity. A held final RGB pixel fences public completion.

Resolve files.f and example/files.f from this package directory. All runtime
dependencies are local; upstream references are not build dependencies.
Current qualification is RTL_CANDIDATE + INTEGRATION_CANDIDATE + HW_UNVERIFIED.
The independently reviewed bounded plan has not run. No synthesis/PnR/STA,
board/PPA, combined compilation or inherited regression is requested.
