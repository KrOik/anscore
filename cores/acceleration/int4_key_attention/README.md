# Resident INT4 key attention

One persistent signed-INT4 key matrix and signed8 value matrix serve successive
U8 query vectors. The original scheduler composes the unchanged resident matvec,
three-pass16-lane integer softmax and autonomous integer divider. It returns one
signed8 weighted-value vector per query. This adds a complete bounded attention
operation to the existing independent matrix/vector and softmax capabilities.

The model exporter supplies key score parameters. Q/K/V projection, training,
dropout, general attention masks, automatic cache append/eviction and multi-head
scheduling are outside this interface. Unused token slots are masked internally.
This specified quantized operation does not claim floating-point attention
equivalence or model accuracy. All hardware properties remain HW_UNVERIFIED.

## Exact numerical contract

Runtime tokens `n` are1..16, query columns `d`1..MAX_COLS, value dimensions
`v`1..MAX_VALUES. For token r:

```text
acc[r]   = signed32(bias[r]) + sum_c((U8(query[c])-U8(x_zero))*S4(key[r,c]))
score[r] = sat_s8(RNE(acc[r]*U16(scale[r])/2^shift[r]) + S8(zero[r]))
e[r]     = EXP[min(15,max(score)-score[r])]
p[r]     = min(255, floor(e[r]*REC[floor(sum(e)/256)]/256))
P        = sum_r(p[r])
out[j]   = RNE(sum_r(p[r]*S8(value[r,j]))/P)
```

RNE means nearest, exact half ties to the even integer, including negative sums.
Score zero offsets are added after score rounding, exactly as in the reused
matvec. The score is in half-logit units for the legacy exponential table; fold
desired temperature and sqrt(d) scaling into model-exported score parameters.

```text
EXP = [255,155,94,57,35,21,13,8,5,3,2,1,1,0,0,0]
REC = [510,170,102,72,56,46,39,34,30,26,24,22,20,18,17,16]
```

The original softmax always runs16 lanes. Slots r>=n receive signed12 -2048,
their exponent and probability are0, and their V records are never read. Actual
score maxima are computed over valid slots. `sum(e)`<=4080 and the REC index is
0..15. At least one e is255, so P is strictly positive in ordinary operation.
Approximate p values can sum differently from255. Dividing by their actual P
preserves a constant value vector and convex signed8 bounds; it does not remove
the relative approximation error of the tables or the signed8 score quantizer.

The score dot/scale widths remain40/57 bits in the unchanged matvec. The new
weighted accumulator is signed21; |sum(p*V)|<=16*255*128=522240. P uses13 bits.
A21-bit unsigned restoring divider computes quotient and remainder of the
absolute numerator; doubled remainder and quotient parity implement signed RNE.
The final result is within[-128,127] without ordinary saturation. `m_score_clip`
and `m_score_inexact` OR their matvec flags over all tokens. `m_prob_clip` reports
at least one approximate probability clamped from>255; the final blend can still
be exact for its weights. A single valid token returns its value exactly and
has P=255, even when the unbounded probability would clip.

## Ports and persistent configuration

Rising-edge clk, synchronous active-high rst, ordinary valid/ready on every public
interface, no public CE or CDC. A source holds valid and its whole payload while
not ready. A sink can stall configuration replies and output rows indefinitely;
every valid output payload stays unchanged. Payload outside valid is unspecified.

| Ports | Width / behavior |
|---|---|
| `c_valid/c_ready` | Configuration command handshake; has priority over cmd at idle |
| `c_op` | 3 bits:0 K packed word,1 score metadata,2 invalidate K/V,3 V packed word;4..7 BAD_OP |
| `c_row/c_word` |16 bits each; token row0..15 and word index |
| `c_data` |32 bits, little-endian packed elements |
| `c_bias/c_scale/c_shift/c_zero` |signed32/unsigned16/unsigned5/signed8 score metadata |
| `c_rsp_valid/c_rsp_ready/c_error` | One held2-bit status:0 OK,1 bad index,2 bad op |
| `cmd_valid/cmd_ready` | New query ownership handshake |
| `cmd_tokens/cmd_cols/cmd_values` |16-bit unsigned runtime geometry, full-width checked |
| `cmd_x_zero/cmd_tag` | U8 query zero point and TAG_W opaque tag |
| `s_valid/s_ready/s_data/s_last` | U8 query stream; LAST must equal column d-1 exactly |
| `m_valid/m_ready` | Value rows or one error marker; LAST retirement ends ownership |
| `m_data/m_index/m_last` |signed8 result,16-bit zero-based value dimension, final-row marker |
| `m_error` |3 bits:0 OK,1 shape,2 missing K config,3 query LAST,4 missing V,5 internal arithmetic fault |
| `m_tag` | Query tag on every row/error |
| `m_score_clip/m_score_inexact/m_prob_clip` | Frame-level flags, constant across ordinary output rows |
| `m_prob_sum` |13-bit actual P used to normalize every row |

K nibble i of c_data stores signed4 column8*c_word+i. A V byte i stores signed8
dimension4*c_word+i. Padding elements in the final packed word are ignored.
Score metadata op1 ignores c_word/c_data. Invalidate op2 ignores all other fields.
Configuration0/1/2 delegates to the unchanged matvec; configuration3 writes the
new V RAM. Each valid bit persists until reset/invalidate; updating one word
replaces it. Bad configuration leaves state unchanged. Physical K/V RAM data is
not reset and cannot be used until its corresponding valid bits are configured.

Parameters MAX_COLS1..1024 (default64), MAX_VALUES1..32 (default8), TAG_W1..32
(default8). Static token capacity is16. A named missing-module guard rejects
unsupported settings. Before admitting query samples, the wrapper validates
shape, then every required V word, then the matvec validates every required K
word and score metadata. Error precedence is shape, missing V, missing K, then
stream LAST. Invalid/missing-configuration commands admit no samples. The
required rectangles are rows0..n-1, columns0..d-1 and V dimensions0..v-1.

## Ownership, failure, CE bridge and reset

One command owns the entire operation through final output retirement. No input
configuration or query command can interleave during collection, key processing,
softmax, value reduction or held outputs. The next command may handshake on the
clock after retirement, never on the same retirement edge. Configuration priority
can starve query offers; arbitrate upstream if that is unacceptable.

A shape/config/LAST error emits one LAST marker with zero data/index/flags/P and
the query tag, with no ordinary output prefix. A wrong LAST stops collection
immediately at the offending accepted beat; it does not drain the rest of a
malformed source vector. The caller abandons that vector and starts a fresh
command after the error marker retires. Missing input beats have no timeout.
Internal reason5 flags impossible zero denominator or out-of-bounds divider
result; this check is not fault-injected and provides no rollback of a previously
delivered output prefix in a hardware fault. Ordinary valid arithmetic cannot
reach it. There is no external memory or retry protocol.

The legacy softmax has a CE-qualified input and registered outputs, not public
ready/valid. The wrapper explicitly enables it only in SM_FEED. SM_READ performs
a synchronous score read; SM_CAPTURE samples that feed's held register results.
It repeats all48 feeds without external output stalls and stores probabilities
before exposing any result. Its retained p_vld cannot create extra public beats.
The matvec/divider use ordinary ready/valid, independently of the private CE.

Reset gates public transfers low immediately and cancels all ownership at the
next rising edge. It invalidates K/V, clears score/probability control and resets
the child cores; RAM payloads remain stale and unreachable. The softmax's inverted
reset is asynchronous while the public reset contract is synchronous: rst must
be asserted across a rising edge to reset the whole composition, not pulsed
between edges. Deassertion is synchronous to the chosen clock at system level;
this module is not a reset synchronizer. A consumer discards an output prefix
without LAST across reset. Reconfiguration is required afterward.

## Architecture, cycle reasoning and offline use

V words, scores and probabilities are inferred synchronous RAM arrays. One
signed9x8 weighted multiply is shared across tokens and value dimensions. The
existing matvec has its9x4 dot and40x17 scaling operators; the original softmax
has8x10 normalization. The new controller uses one existing21-cycle divider.
There is no parallel token/channel MAC array or combinational division.

Logical RAM payload defaults to5888 bits: K4096, query512, V1024 and score/P256.
Maximum is78080 bits: K65536, query8192, V4096 and score/P256. These exclude
metadata, valid bits, child pipeline slots and scalar registers. Architecture
risk MEDIUM, including serial variable latency, several small memories and wide
score scaling. Resource figures are structural bit budgets, not mapped results.

V precheck uses n*ceil(v/4) clocks; the matvec then performs its own precheck,
query capture and serial dot products. From the final score handshake, the48
softmax feeds occupy exactly144 clocks. First ordinary output becomes visible
167+2*n clocks after that score handshake. After an output-row retirement, the
next row becomes visible2*n+23 clocks later, with earliest transfer the following
edge. These counts follow the source FSM and exclude external producer gaps,
output holds, reset and faults; no independent latency assertion is claimed by
the finite numerical TB. No hardware MHz or seamless query-rate claim is made.

Both `files.f` and `example/files.f` resolve from this package directory. All four
unchanged dependencies are canonical repository paths, listed once each, with no
internet, vendor primitive, ROM download or generated coefficient requirement.
`example/two_token_attention.sv` is an actual boot-configured instance: it writes
two keys, score metadata and two values, accepts one-byte queries and returns
two-channel responses. Queries0/128/255 produce(-62,+62)/(0,0)/(+62,-62) under
the specified fixed-point model. Its boot fault output makes config failures
visible; output backpressure delays the next accepted query.

`python run_checks.py` archives exact execution inputs and generates three finite
vector fixtures before any Icarus child. Each child has a20-second deadline,
bounded process-tree cleanup and raw logs/hashes; first failure stops the plan.
It never launches synthesis, PnR, STA, board tests, a full inherited regression or
PPA work. The delivery bridge records actual results and coverage.

The single run `reports/20261105T191506834125Z/results.json` has11 PASS children:
default/max/example syntax, three compile/simulation profile pairs and the actual
boot-example compile/simulation pair. No failed/timed-out child or retry occurred.
Profiles `(MAX_COLS,MAX_VALUES,TAG_W)` are `(1,1,1)`, `(9,3,8)` and `(64,32,32)`;
the1024-column static maximum is syntax checked only. Matvec/query prefixes,
non-word-aligned columns/values, all16 tokens and full32 value dimensions are
numerically exercised in these finite fixtures.

The ordinary fixtures check2876 configuration replies,102 query responses,
444 ordinary value rows and54 error markers. They hold498 vector output rows/
markers for1473 stalled clocks. Fifteen reset scenarios cancel query admission,
softmax feed, divider work, held output and held configuration, with post-reset
missing-configuration recovery. Three additional priority flows check a legal
query continuously offered behind config and a real future config held through
output retirement; their accepted write is confirmed by the following query.
The boot example checks three queries and six value channels. Finite patterns
cover signed minima, constant V, signed RNE half ties, exact/nonexact and clipped
scores, approximate probability clipping, LAST errors, missing/invalid config,
all-clear/reconfigure, captured command changes and output backpressure.

The independent oracle uses Python integer dot products, independently stated
table constants and exact quotient/remainder rounding, without importing model
frameworks or reference scripts. Compiler logs contain inherited/missing
timescale warnings for delay-free production modules and dependencies. These scoped results earn LINT_PASS,
UNIT_SIM_PASS and INTEGRATION_CANDIDATE, alongside HW_UNVERIFIED. No input-domain
exhaustion, independent latency assertions or hardware qualification is claimed.
