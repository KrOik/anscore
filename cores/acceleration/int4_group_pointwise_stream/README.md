# Resident INT4 grouped pointwise stream

This pixel-at-a-time NHWC engine computes grouped 1x1 convolution, optionally
transposing the group/output-channel axes. It owns packed resident S4 weights,
per-row quantization metadata and one pixel buffer. It processes a runtime
number of pixels without a frame RAM, external memory or CPU scheduling.
It reuses the unchanged committed `int4_weight_matvec/rtl/deps/stream_requantize.v`.
Current status: RTL_CANDIDATE / HW_UNVERIFIED; all proposed checks are NOT_RUN.

For each pixel, group g and group-local output row r:

```
a[g,r] = S32(bias[g,r]) + sum_i((U8(x[g,i])-U8(x_zero))*S4(W[g,r,i]))
y[g,r] = sat_s8(RNE(a[g,r]*U16(scale[g,r])/2^shift[g,r]) + S8(zero[g,r]))
```

RNE uses exact half ties to the even integer, including negative values. The
zero offset is added after rounding. `m_inexact` means nonzero discarded
fractional bits; `m_clip` means final S8 saturation. Zero scale is legal.
Input is U8; an S8 producer can xor its sign bit with128 and use x_zero128.
There is no model-scale conversion, activation, training or claimed equivalence
to a floating CNN or a particular model export ABI.

GROUPS is static1..8. Each group has runtime input/output counts1..its static
maximum. GROUPS*MAX_IN_PER_GROUP<=1024, GROUPS*MAX_OUT_PER_GROUP<=64;
MAX_PIXELS1..4096, TAG_W1..32. Defaults are2/8/8/4096/8. Illegal static
settings elaborate an unresolved named guard. All public command/configuration
indices are16 bits and checked before truncation; high invalid bits cannot alias
valid RAM. Runtime input and output counts are per group, not total channels.

One rising-edge clock, synchronous active-high reset, ordinary valid/ready;
there is no CE or CDC. Reset masks all public transfers, cancels every owner
and invalidates all configuration at the next active edge. Payload RAM is not
reset. Assert reset across an active edge and reconfigure before new inference.
Sources keep valid and payload stable until handshake; all result/reply fields
stay stable while blocked. There are no input, output or completion timeouts.

Configuration is available only when idle; it wins a simultaneous command:

| c_op | Operation |
| --- | --- |
| 0 | Write packed weight word at c_group/c_row/c_word. Nibble i is signed4 input8*c_word+i. Padding nibbles beyond the runtime count are ignored. |
| 1 | Write signed32 bias, unsigned16 scale, shift0..31 and signed8 zero at c_group/c_row; c_word/weights are ignored. |
| 2 | Invalidate all rows and words; all other fields ignored. |
| 3 | Unsupported; no mutation. |

`c_error` is0 OK,1 invalid index,2 unsupported opcode. One held c_rsp owns
each configuration response. A bad config does not invalidate existing state.
All selected groups/rows/packed words must be configured; precheck finishes
before any input is accepted. Unselected rows/columns do not matter.

Command captures pixel count, per-group input/output counts, U8 zero point,
shuffle bit and opaque tag. Input order is pixel, then group, then input channel.
`s_last` must be true only on the final sample of the complete frame. Ordinary
output has the same pixel count, with GROUPS*out_per_group samples per pixel:

| Shuffle | Output source order within a pixel |
| --- | --- |
| 0 | group first, then local row: (0,0),(0,1),...,(1,0),... |
| 1 | local row first, then group: (0,0),(1,0),...,(0,1),... |

`m_channel` is the sequential channel index after this ordering; `m_group/m_row`
identify the weight row used. `m_pixel` is the zero-based pixel index, `m_last`
marks the final output sample and every output carries the command tag.
Shuffle is performed by computation order, without an output permutation RAM.

The separate completion channel is the definitive frame result. `rsp_error`:
0 success,1 bad shape,2 missing configuration,3 wrong input LAST. `rsp_outputs`
counts transferred scalar outputs and rsp_tag identifies the owner. Errors1/2
accept no input and emit no numerical outputs. Error3 stops input immediately;
the caller abandons the remainder, discards all earlier pixel outputs from that
frame, and starts a fresh command after completion. Missing beats wait forever;
there is no implicit drain or retry. No current pixel output is exposed before
its whole input pixel has been collected and checked. All commands/config are
blocked through arithmetic, held numerical outputs and held completion. The
next command is eligible on the cycle after completion retirement.

The actual `two_rgb_group_projection` example boots four resident rows and
serializes two packed RGB views into the engine. It emits packed centered luma
and opponent features in shuffled order: left luma, right luma, left R-G, right
R-G. Luma weights are[2,4,1]/8; opponent weights[1,-1,0]; x_zero128, zero0.
Packed input byte order is left R/G/B then right R/G/B, low byte first. The
example packs four S8 result bytes, holds metadata under stalls, bounds accepted
pixels, and withholds completion until the final packed output retires. Its
rsp_outputs retains the scalar engine count (four times successful pixel count).
Bad LAST results have the same discard-whole-frame rule. Reset restarts the
fixed configuration boot, during which cmd_ready is low.

`files.f` and `example/files.f` are evaluated from this package directory.
The sibling dependency is already committed in baseline
`d32ea87e268c5957b7203560a5b46864e282a6e1`; its standalone uncommitted lookalike
is deliberately not a dependency. There are no ROMs or fetched weights.
See ARCHITECTURE.md and SOURCES.md. The finite plan will list syntax, four
isolated vector preparations and four deterministic simulations. No synthesis,
PnR, STA, board, power or physical throughput evidence is requested or claimed.
