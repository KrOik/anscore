# INT4 frame-global squeeze and excitation

This core caches a signed8 NHWC feature map, derives a channel descriptor with
the unchanged global-average-pool core, runs two resident INT4 dense layers with
an intervening ReLU, forms exact quantized hard-sigmoid gates and replays the
feature map with channel scaling. The gate depends on the entire spatial frame.
It adds channel recalibration to existing pooling, dense and token-attention
primitives. It is a specified integer operation, without training-accuracy or
floating-point-network equivalence claims.

For pixels P, channels C and bottleneck H, the mathematical contract is:

```
a[c] = RNE(sum_p S8(x[p,c]) / P)
u[h] = max(0, sat_s8(RNE((bias0[h] + sum_c a[c]*S4(W0[h,c]))
                        * U16(scale0[h]) / 2^shift0[h]) + S8(zero0[h])))
z[c] = sat_s8(RNE((bias1[c] + sum_h u[h]*S4(W1[c,h]))
                  * U16(scale1[c]) / 2^shift1[c]) + S8(zero1[c]))
g[c] = clamp(RNE(4*(z[c]+96)/3), 0, 256)
y[p,c] = RNE(x[p,c]*g[c]/256)
```

RNE is nearest integer with exact ties to even, including negative values. Each
dense-layer zero point is added after rounding. The second-layer result z is in
units of 1/32 for hard-sigmoid `clamp(z/192+1/2,0,1)`. Gates use nine-bit Q0.8,
including both 0 and 256; unity therefore preserves every signed8 input exactly.
The final convex scaling remains in signed8 and has no saturation stage. Hidden
ReLU operates on quantized signed8, not an unrounded accumulator. Exporters must
choose weights, scales and zero points for this precise contract.

All ports share a rising-edge clock with synchronous active-high `rst`; no CE,
CDC, external memory or vendor primitive is used. A transfer is `valid && ready`.
Sources hold all fields until acceptance. Outputs, configuration replies and
completion replies hold their complete payload under arbitrary backpressure.
Reset immediately suppresses public ready/valid, cancels active ownership at a
rising edge and invalidates both matrices. RAM payload is not reset; every used
location is written before an ordinary read. A consumer discards a delivered
prefix without LAST when reset cancels a frame. No input/stall timeout exists.

Static ranges: MAX_CHANNELS 1..64, MAX_HIDDEN 1..32, MAX_PIXELS 1..4096,
TAG_W 1..32; defaults 16/4/256/8. Unsupported static values elaborate a named
missing module. Runtime command fields are full unsigned16 and require nonzero
pixels/channels/hidden within the static limits. The tag and dimensions latch
on command acceptance. One frame owns the entire core until its separate held
completion retires; final output retirement alone does not release ownership.

`c_bank=0` addresses W0: MAX_HIDDEN rows, MAX_CHANNELS columns. Bank1 addresses
W1: MAX_CHANNELS rows, MAX_HIDDEN columns. Configuration has priority over a
command at idle. Opcodes and fields match the reused resident matvec:

| c_op | Effect |
|---|---|
| 0 | Write `c_weights`, eight little-endian signed4 nibbles, row `c_row`, word `c_word`. |
| 1 | Write signed32 bias, unsigned16 scale, unsigned5 shift, signed8 zero for `c_row`. |
| 2 | Invalidate weights and metadata in the selected bank only. |
| 3 | BAD_OP, no mutation. |

Held `c_rsp_valid` returns `c_error`: 0 OK, 1 index out of range, 2 BAD_OP.
Padding nibbles after the active column count are ignored. Writes persist across
frames; a word rewrite leaves all other validity intact. Full-width indices are
validated before indexing. Mirrored validity commits only after a successful
configuration response retires, and commands remain blocked until then. Both
required rectangles are checked before accepting any feature-map sample.

Input order is pixel-major/channel-minor. Exactly P*C signed8 beats are required;
`s_last` must be true only at the final beat. An offending LAST is consumed and
aborts immediately; the caller abandons any unsent suffix. There is no drain or
automatic retry. Malformed input produces no ordinary output. Shape/configuration
errors accept no samples. After a valid complete frame, outputs replay NHWC order
with zero-based `m_pixel/m_channel`, captured `m_tag`, and `m_last` on the final
beat. `m_gate` gives the actual Q0.8 channel gate and `m_inexact` marks nonzero
fractional bits in that beat's final scaling.

Five frame-level flags stay constant throughout ordinary outputs:
`m_mean_inexact` ORs nonzero pool remainders; `m_projection_clip/inexact` OR the
two dense layers' quantization flags (before hidden ReLU); `m_gate_inexact` marks
nonzero gate-division remainders in the open interval -96<z<96;
`m_gate_clamped` marks a logit strictly outside [-96,96]. Endpoint logits are
exact gates and do not set clamp/inexact. Flags outside ordinary output valid
are unspecified.

Completion is `rsp_valid/rsp_ready` with tag, actual accepted-input count and
actual retired-output count, both unsigned24. `rsp_error`: 0 success, 1 shape,
2 missing configuration, 3 LAST mismatch, 4 unexpected child/division fault.
`rsp_stage`: 0 reduce, 1 expand, 2 pool, 3 no failing stage. `rsp_child_error`
passes through a child error (zero for normal/precheck errors); malformed LAST
is pool error2. Error4 is unreachable for ordinary valid arithmetic and is
source-reviewed, without fault injection. No output-prefix rollback in an
internal hardware fault is promised. Reset is the explicit cancellation method.

`files.f` is the complete offline source closure, relative to this directory.
`example/files.f` also includes a real boot-configured RGB example. That wrapper
uses a one-neuron sum/ReLU and weights [-1,0,+1] to derive three different gates;
`boot_fault` exposes configuration failure. It admits commands only after all
eight weight/metadata replies succeed, and reboots on reset.

Validation status is **RTL_CANDIDATE / INTEGRATION_CANDIDATE / HW_UNVERIFIED**
until exact reviewed finite execution is recorded in DELIVERY.md and
QUALIFICATION.json. The new source-only integer oracle and testbench cover
legal arithmetic, zero/unity/half gates, signed ties, configuration lifetime,
framing, boundary shapes, stalls, held future offers and reset recovery. Nothing
has yet executed. Maximum dimensions do not imply full maximum-frame throughput
qualification. No synthesis, PnR, STA, board, inherited regression or PPA is run.
