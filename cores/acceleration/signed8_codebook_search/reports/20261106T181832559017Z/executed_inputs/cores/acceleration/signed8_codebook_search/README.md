# Resident signed8 codebook search and reconstruction

This original integer inference core searches a persistent signed8 codebook for
the closest query vector, using exact squared Euclidean distance. It emits the
lowest-index winner, its distance, the gap to the second-smallest distance, and
the selected codeword with exact signed9 residuals. There is no training,
floating-point scale conversion, approximate search or claimed model accuracy.
Codeword and query components must use the same externally chosen units.

Parameters MAX_CODES=16 (1..64), MAX_DIMS=16 (1..256), TAG_W=8 (1..32).
Every distance is an unsigned24 integer: at most 256*255^2=16,646,400.
Both input and codeword components are signed two's-complement8 integers.
One clock, synchronous active-high reset, ordinary valid/ready, no CE or CDC.
All transfers require reset low. Reset suppresses every public ready/valid,
cancels all work and replies, invalidates all codebook prefixes, and requires
reconfiguration. Payload RAM is not cleared.

## Persistent configuration

While idle, cfg_valid/cfg_ready accepts one component and returns a held
cfg_rsp_valid reply, consumed with cfg_rsp_ready. Replies echo cfg_code and
cfg_dim. A successful cfg_first=1 write must have cfg_dim=0; it starts or
replaces that row, stores component0 and publishes prefix length1. An append
with cfg_first=0 requires a nonempty row and cfg_dim equal to its current
prefix length. It stores that component and extends the prefix. A restart
invalidates the old suffix immediately. No previous suffix can be searched
until it has been appended again.

cfg_status 0 means success, 1 means code/dimension outside the static capacity,
and 2 means an invalid start or append order. Rejected writes change no RAM or
prefix. No new operation is admitted while its reply is held. Configuration
wins a simultaneous idle command: c_ready is low when cfg_valid is high.
Keep every source field stable while its valid is blocked.

## Query, summary and reconstruction

A c_valid/c_ready command captures c_codes (actual count1..MAX_CODES), c_dims
(actual count1..MAX_DIMS) and c_tag. Rows0 through c_codes-1 are searched over
their first c_dims components. Live configuration inputs cannot alter active
work. Each requested row must already have a prefix at least c_dims long.

The core checks all prefixes before asserting s_ready. Supply exactly c_dims
signed8 values on s_valid/s_ready edges, in ascending dimension order. There
are no framing markers: the accepted count defines the vector. Missing input
waits indefinitely; reset is the explicit cancellation mechanism. Additional
input is not accepted after the configured count.

One held m_valid summary follows. m_error=0 is normal; 1 rejects zero or
oversized runtime counts; 2 rejects an incomplete codebook prefix. Errors
consume no query components and produce code/distance/margin/second_valid=0.
Consume the error summary before another operation. The original tag is
returned in m_tag. An error produces no reconstruction stream.

For a normal summary, m_code selects the smallest-index row among equal
minimum distances. m_distance is that exact minimum. If at least two rows
were requested, m_second_valid=1 and m_margin is second-smallest minus minimum;
ties between different rows therefore give margin0. With one row, the flag
and margin are zero. The margin is a distance gap, not a probability.

After the normal summary retires on m_valid/m_ready, reconstruction emits
c_dims beats on r_valid/r_ready. r_dim counts0..c_dims-1; r_value is the selected
signed8 codeword component, r_original is the cached query component,
r_residual=r_original-r_value is exact signed9, and r_last marks the final
dimension. r_tag repeats the captured tag. All output fields remain stable
under backpressure. The core admits the next operation after the last replay
beat retires. There is no extra completion channel. Accepted prior summary
or replay beats cannot be rolled back by reset.

## Actual composition

example/codebook_residual_encode.sv connects replay residuals to the unchanged
canonical stream_requantize implementation. Its e_value is
sat_signed8(RNE(residual/2^c_residual_shift)), with exact nearest-even ties,
e_clip and e_inexact. The four-bit shift is captured with each command; shifts
9..15 return zero and report inexact for a nonzero residual. Tag, dimension
and LAST pass through the elastic quantizer with the sample. Summary ports
and configuration retain the core semantics.

The wrapper may admit a new command while old final encoded beats remain in
the quantizer. Encoded vectors remain ordered, with their own tags and LAST;
each accepted residual already carries its own shift and metadata. Reset
flushes both blocks. There is no promise of one command outstanding through
the final e_last handshake. Both files.f lists resolve from the package root.

## Current qualification

RTL_CANDIDATE, INTEGRATION_CANDIDATE, HW_UNVERIFIED. The new RTL and example
have not been compiled or simulated. Finite checks require frozen exact
source/tool/plan pins and full root plus independent peer review first.
Synthesis, PnR, STA, board tests, PPA and historical regressions are NOT_RUN.
