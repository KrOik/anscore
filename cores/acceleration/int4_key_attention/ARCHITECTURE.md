# B36 pre-implementation architecture decision

Baseline: 8ba6835fe51ad285b926cd24e3ba4d172aefce26. Task: persistent INT4 keys,
U8 queries, signed8 values -> one bounded quantized attention output vector.
Before RTL, repository source/README/SPEC/catalog searches found no attention
service. Existing INT4 matvec supplies resident keys and exact score quantization;
existing ips_softmax_fixed supplies a three-pass16-lane integer approximation;
integer_divider supplies autonomous exact quotient/remainder. YOLO depthwise
convolution and sparse matvec implement different operations. All are inspected
at actual source level; dependencies remain unchanged at canonical paths.

One query owns the block through its final output retirement. Runtime1..16
tokens,1..MAX_COLS query dimensions,1..MAX_VALUES output dimensions. Defaults
64 query and8 value dimensions; maxima1024/32. One original controller schedules:
precheck V words -> original INT4 matvec -> score RAM -> three CE-qualified
softmax replays -> probability RAM -> one value weighted-sum lane ->21-bit
unsigned division -> signed RNE output. Persistent K/V support successive queries.
No Q/K/V projection, training, KV append/cache eviction, masks beyond unused
tokens, multi-head scheduling or floating-point-equivalence claim is made.

The original matvec computes saturated signed8 scores with per-key bias/scale/
shift/zero. A score unit corresponds to a half-logit for the existing exp table.
The model exporter folds desired temperature/sqrt(d) into those score parameters.
Unused softmax lanes receive signed12 -2048, so their quantized exponent is0.
The approximate softmax probabilities can sum differently from255; the output
uses their actual positive sum as denominator, preserving constant V rows and
convex bounds. The exact contract is RNE(sum_i(p_i*V_i,j)/sum_i(p_i)).
This is quantized attention with a specified LUT, not exact exponential softmax.

Numerator magnitude is bounded by16*255*128=522240; signed21 accumulation
and unsigned21 division are sufficient. P sum uses13 bits, with bound4080.
One signed9x8 weighted-sum multiplier is time-shared across tokens and channels.
Underlying matvec adds9x4 and40x17 multipliers; softmax adds8x10. There is no
parallel token/channel MAC grid or new wide divider implementation.

Default packed RAM payload: keys4096 bits, query512, V1024, scores128,
probabilities128, total5888 bits; max keys65536/query8192/V4096/scores+prob256,
total78080 bits, excluding key metadata/valid bits and scalar buffers. Sequential
read/MAC alternation permits synchronous RAM. Risk MEDIUM: variable serial
service, small independent memories, wide matvec rescale and CE/valid bridging.
No synthesis, fit, timing, power or measured throughput is inferred.

Configuration0/1/2 delegates K word/score metadata/invalidate to unchanged matvec;
configuration3 writes a packed V word. Invalidate and reset also clear V validity.
Configuration responses and output rows are held. Errors are single LAST markers
with zero data and no ordinary output prefix. Reset cancels ownership and
invalidates all K/V; no rollback across reset. Only finite syntax/unit simulation
is planned after complete source/vector archival, with20-second child deadlines.
