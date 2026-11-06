# Resident INT4 subpixel upsampling layer

For each NHWC U8 input vector at(y,x), calculate4*Cout learned INT4 rows using
the unchanged resident matrix engine. Its row `r=(2*dy+dx)*Cout+c` becomes the
signed8 output at(2y+dy,2x+dx,c). This is a 1x1 learned channel projection followed
by DCR depth-to-space2, suitable as a quantized decoder layer. It does not bundle
a pretrained model or establish image quality or whole-network compatibility.

`acc[r]=bias[r]+Σ((U8(x[i])-U8(x_zero))*S4(weight[r,i]))`

`output=sat8(RNE(acc*U16(scale[r])/2^shift[r])+S8(zero[r]))`

All intermediate sums/products are exact in the stated domain; round once before
adding output zero. Negative ties round to even. Clip and inexact are independent
and are carried through the spatial permutation. `rgb_subpixel8` is the named
8-feature/3-output-channel fixture; output samples remain signed bytes, not packed
RGB24. The core's actual integration is the existing matrix and quantizer.

One rising-edge clock, synchronous high reset, no CE/CDC. All transfers use
ordinary valid&&ready. Sources hold blocked payloads. Outputs and completion hold
under arbitrary stalls; there is one frame in flight including held completion.
Reset cancels everything and invalidates matrix weights; RAM payload is not reset.
Ready/valid is suppressed during reset. Legacy CE streams need an explicit adapter.

Static maxima: input channels1..64(default8), output channels1..16(default4),
width/height1..1024(default64), TAG1..32(default16). Unsupported static values
elaborate a named missing module. Runtime nonzero dimensions/channels fit these
maxima. Command acceptance snapshots dimensions, input zero and opaque tag.

Configuration passes to the resident matrix only in idle. c_op0 writes packed
32-bit weight word to c_row/c_word (eight signed4 nibbles, low nibble first);
c_op1 writes signed32 bias, unsigned16 scale, shift0..31 and signed8 zero to row;
c_op2 invalidates all rows/words, c_op3 returns error2. Range errors return1;
successful configuration returns0. Padding nibbles are ignored. Every used word
and every selected row metadata must be configured. Configuration wins a
simultaneous frame offer and its held response blocks frame acceptance. Weights
persist across normal frames; no model files or external memory are required.

Input ordering is y,x,channel. SOF is true only on the first sample; EOL is true
only on the final channel of the final pixel of every source row; LAST is true
only on the final sample. Each matrix precheck precedes its pixel input. Wrong
markers abort at that accepted sample, with no implicit drain/replay. The caller
stops that frame when completion reports an error, then reconfigures after a
marker or internal error because the matrix was flushed. A source that never
supplies required data has no timeout.

Output ordering is expanded y,x,channel. Coordinates are0-based and include
both spatial phases. SOF/EOL/LAST follow the equivalent expanded-frame rules.
Upper rows stream directly; lower rows replay from one row RAM. All outputs
are provisional until held completion: rsp_error0 success,1 bad dimensions,
2 missing configuration,3 bad input markers,4 child/internal inconsistency.
Errors1/2 preserve existing configuration;3/4 invalidate it. rsp_inputs counts
accepted public samples (including a bad-marker sample), rsp_outputs counts
actual retired public samples. Error3/4 may follow partial outputs; discard the
whole failed frame. A completion cannot precede a held final output.

Resolve files.f or example/files.f from this package directory. All sources and
dependencies are local. [ARCHITECTURE.md](ARCHITECTURE.md) records storage and
cycle reasoning; [SOURCES.md](SOURCES.md) records semantic deduplication and
fixed external reference/license checks. New code is Apache2; mature dependencies
are used unchanged and their historical hardware evidence does not qualify this
new layer. Current state RTL_CANDIDATE + INTEGRATION_CANDIDATE + HW_UNVERIFIED,
pending the separately reviewed finite plan. No synthesis/PnR/STA/board/PPA or
inherited regression is requested.

The proposed finite qualification has three archived Python preparations (zero
planning oracle calls), followed by default/maximum/example syntax and three
compile/simulation pairs. Profiles have static bounds1/1/1x1/TAG1,
9/3/7x5/TAG8 and64/16/1024x1024/TAG32. The maximum profile includes a complete
1024-pixel,16-channel lower-row fill/replay as well as one64-input/16-output
pixel; it does not run the full1024x1024 frame. The named RGB fixture gets syntax
coverage; functional core tests execute the real matrix/quantizer integration.
The independent arbitrary-integer tensor oracle has no RTL or child-model imports.
Directed cases cover missing configuration, invalid dimensions/channels, held
configuration/errors, ordinary failed writes, persistent weights, early malformed
SOF/EOL/LAST, partial top-row abort, flush/reconfigure/future frames, signed32
bias/maximum scale, clipping/inexact, input gaps, top/lower output stalls, held
completion and preoffered commands. Five additional live reset phases each
require a newly configured, numerically checked future frame. Every child has a
20second deadline plus5second tree termination and2second pipe drain, and the
first failure stops all later launches without retries. Exact sources, tools,
vectors, raw logs and compiled images remain bound to the selected receipt.
