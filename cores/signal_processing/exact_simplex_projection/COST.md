# Architectural budget; no synthesis or timing measurements

The chosen bounded deletion scan trades quadratic worst-case work for one small
multiplier and one RAM. A sorting-network implementation has more comparators and
records; composing the existing frame sorter would require preserving original
order and a second sample/order store. The chosen method stores one input vector
and an active bitmap. Existing single-frame ownership, synchronous-memory and
exact-rational interface conventions informed the design; no old RTL arithmetic
is imported and no source-code reuse is claimed.

| Logical resource | Default N16/W16/T8 | Maximum N64/W24/T32 |
|---|---:|---:|
| Sample RAM N*W | 256 bits | 1536 bits |
| Active bitmap | 16 bits | 64 bits |
| Multiplier operands, full result | signed16 × positive signed6 → signed22 | signed24 × positive signed8 → signed32 |
| Shared wide add/subtract | 22 bits | 32 bits |
| Shared product/threshold comparator | signed22 | signed32 |
| Index | 4 bits | 6 bits |
| Three count/round registers | 3×5 bits | 3×7 bits |
| Scalar registers, including state/index, excluding bitmap/RAM | 149 bits | 237 bits |
| Scalar + active bits | 165 bits | 301 bits |

Scalar accounting is `4+INDEX_W+2*W+3*COUNT_W+2*A_W+P_W+TAG_W+U_W`.
The two W registers are RAM read data and frame mass; two A_W registers are sum
and threshold. No reset is applied to RAM, arithmetic registers or the bitmap.
FSM recoding and physical RAM/multiplier mapping can change actual resource use.
The logical storage budgets are consistent with the initial envelopes of <=256
default scalar bits and <=384 maximum scalar bits, but are not physical FF counts.

From final input acceptance through final output retirement, with ready always high:

```
C(N,r) = 1 + r*(3*N+1) + 4*N, 0<=r<=N
M=0: r=0
M>0: 1<=r<=N
C_upper = 1 + N*(3*N+1) + 4*N
```

The one clock initializes the pass or zero-mass path; each pass takes three clocks
per item plus one PASS_END; each output takes READ, MULT, CHECK and retirement.
This includes synchronous RAM latency, multiply registers, all pass boundaries,
the first output and final retirement exactly once. The conservative bounds are
849 clocks at default and 12609 at maximum. With N contiguous input acceptances,
the always-ready interval between consecutive frame starts is bounded by N+C_upper:
865 default, 12673 maximum. Input gaps add accepted-input wait clocks and each
stalled output edge adds one occupancy clock. Unbounded backpressure gives no
unconditional completion guarantee. After the first output, always-ready outputs
retire every four clocks.

These are source-level schedule bounds, awaiting approved finite simulation.
Potential critical paths are the natural multiplier, signed product comparison,
wide add/subtract and indexed bitmap logic. Registering the product cuts the
RAM→multiply→compare/sum dependency into phases. No clock frequency or DSP mapping
is promised; power and PPA are unmeasured. No external memory or unsupported hard
block is assumed.
