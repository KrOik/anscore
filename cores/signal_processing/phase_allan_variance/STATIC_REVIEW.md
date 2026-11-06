# B41 pre-execution structural review

Scope is new source and bounded architecture, not an executed tool result.

- Whole-record versus streaming-ring algorithms were compared. Full-record
  capture was selected for II1 acquisition and simple one-port synchronous reads;
  512B default/8KiB maximum is bounded. A ring saves memory but would stall
  acquisition for each serialized square or need parallel arithmetic/FIFOs.
- Exact differences need W+2 signed bits; the full numerator bound is
  `(N-2m)*(2^(W+1)-2)^2`. No signed-helper sign bit aliases an unsigned operand.
  The numerator shift16 and RNE extension retain all significant bits.
- Arithmetic is time-shared: one18x18 CSA/fold helper, one iterative divider,
  one accumulator. m does not unroll logic. All memory addresses are below N;
  payload RAM is not reset. No external memory or device primitive is assumed.
- Single ownership prevents command/data/result mixing. Invalid commands
  consume no samples; early LAST stops immediately, missing LAST stops at N,
  and invalid samples are explicit. Error arithmetic fields are zero.
- Public synchronous reset gates ready/valid. The multiplier/capture local
  asynchronous reset assertions originate at rising clk. Held records cannot
  change or be overwritten. Helper results are accepted only in matching states.
- Trigger example forwards the stored invalid bit, uses the original capture
  module and fixed256 record length, and gates invalid arms before capture.
- Source lists expand the closure directly. No nested -f, hidden include,
  helper clone or vendor-specific module enters production.
- MEDIUM qualitative architecture risk. Storage inference, timing, area,
  clock frequency, power and physical measurement accuracy are unverified.
- Future finite plan covers minimum/nonpower/maximum profiles, full4096
  maximum numerator and denominator, exact even/odd half ties, command mutation,
  strict markers/invalid precedence, gaps/II1, held outputs, every active state
  reset, partial-capture reset, defensive divider fault and subsequent recovery.

No oracle, preparation, HDL, old regression or physical design tool was executed
to produce this source review. Root independent review precedes all execution.
