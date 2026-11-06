# Arithmetic and ownership decisions

The objective is an exact adjacent-spectrum instrument with modest shared
arithmetic and explicit backpressure. A fully parallel multiplier per bin would
spend area on an operation used once per captured frame. Pre-rounding individual
probabilities would destroy exact scale invariance and final tie behavior.
The chosen first version uses exact cross-products, one shared serial multiplier,
one restoring divider and two single-port synchronous memory banks.

For N<=M=MAX_BINS<=256 and unsigned32 powers, put S=32+ceil(log2(M)).
A,B<=M*(2^32-1)<2^S. Every P*B/Q*A fits2S bits. The positive-difference
sum U equals half the absolute-difference sum because normalized masses each
sum to one; consequently0<=U<=A*B<2^(2S). A2S-bit numerator suffices without an
extra log2(N) growth beyond the denominator width. The controller nevertheless
checks the accumulator carry and final U<=D invariant before dividing.

The logical signed difference needs2S+1 bits. RTL implements its positive part
by an unsigned comparison followed by subtraction only when first>second, so a
negative term cannot wrap into the accumulator. Products are registered between
the helper and subsequent difference/accumulation. No wide combinational product
and accumulation chain appears in new RTL.

The unsigned divider width is W=2S+16; numerator is the concatenation {U,16'b0}
and denominator is zero-extended D. Exact floor quotient and remainder support
one ties-to-even decision using a W+1-bit doubled remainder. The rounded value
must be<=65536 and is emitted in17 bits. A nonzero remainder sets inexact even
when the rounded result is0 or65536. Division by zero is excluded by explicit
zero classification, with an arithmetic fault marker if a helper contradicts it.

Each bank instantiates the existing byte-write cip_sync_sp_ram at32 bits and
depth M; clk_en and rsp_ready are tied high. Candidate writes can transfer on
every clock. The separate CLASSIFY state drains the final write response.
Paired replay requests issue only when both RAM request endpoints are ready;
both registered responses are then consumed together. There is no same-bank
simultaneous read/write schedule or reset loop over payload memory.

Reference bank, stored total and length change only when a valid-frame summary
retires. Errors never write those reference words. History validity clears on a
damaged accepted frame or reset. Configuration rejection preserves it. Valid zero
frames still commit and retain temporal adjacency. A restart or changed length
selects WARMUP for that current frame, and commits only after its summary retires.

Helpers receive a registered active-low reset bridge. External synchronous reset
holds the bridge low for a complete edge; public command readiness waits for
reopening. ARITH and damaged input errors enter FLUSH with bridge low before
their summary can become valid. The multiplier and memory reset transitions
therefore occur at clock edges and cannot leak an old arithmetic response into
the next command. Divider reset is synchronous and also sees that complete edge.

For S at maximum40, multiplier response-transfer latency is51 clocks and divider
latency97. Each replay row consumes2Lm+4=106 clocks between paired-read requests.
First read follows capture/classification; final row is followed by total-product
and division stages. Thus compatible nonzero first-valid is
N*(2Lm+5)+Lm+Ld+3. The additional ready edge after retirement prevents a new
command on the retirement edge. I/Q adds four input-pipeline clocks. Unbounded
backpressure gives no unconditional wall-clock or sample-rate guarantee.

No execution, synthesis, mapping, timing or power measurement underlies these
estimates. The exact service schedule and RAM/multiplier boundaries are explicit
source-review subjects; a future finite simulation can confirm them without
claiming physical timing closure.
