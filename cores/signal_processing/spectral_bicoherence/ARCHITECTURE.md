# Function, widths and serialized service budget

The target is a finite spectral measurement with ordinary backpressure, no
required clock frequency and no physical PPA qualification. A fully parallel
triple-product path would add four D*D and four (2D+1)*D signed products plus
wide normalization products. Because one record may take many clocks, the
first implementation chooses one shared unsigned carry-save multiplier and
one restoring divider. Magnitude operands and a captured sign perform exact
signed multiplication; unsigned magnitude represents signed minima safely.
This trades latency for a compact, explicit arithmetic schedule.

Let D=DATA_W, L=ceil(log2(MAX_AVERAGES)), with L=0 at MAX_AVERAGES=1:

| Node | Width and signedness | Bound/role |
|---|---|---|
| Original components | signed D | -A..A-1, A=2^(D-1) |
| Individual XY real products | signed 2D | Full product |
| Pr,Pi | signed P=2D+1 | Exact difference/sum of two products |
| Individual P*Z products | signed P+D | Full product |
| Tr,Ti | signed T=3D+2 | Exact sum/difference, no narrowing quantization |
| B accumulators/output | signed B=T+L | K<=2^L exact terms |
| U | unsigned U=2P+1+L | Sum of K exact Pr^2+Pi^2 |
| V | unsigned V=2D+1+L | Sum of K exact Zre^2+Zim^2 |
| B numerator | unsigned N=2B+1 | Br^2+Bi^2 |
| Denominator | unsigned H=U+V=N-1 | U*V |
| Integer divider | W=N+16 | Numerator shifted16, denominator zero extended |

Since each complex input magnitude squared is at most2*A^2,
`|XY|^2<=4*A^4`, `|XYZ*|<=sqrt(8)*A^3` and
`|Tr|,|Ti|<4*A^3`. The selected signed widths cover both signs and all extrema
with margin; the unsigned energy widths also cover K=MAX_AVERAGES when this
is a power of two. Addition guards retain an extra bit before narrowing.
Conjugation is achieved by the two product signs, without negating an
input minimum in its signed width. All stored exact-product slices are
within these proven ranges.

Cauchy for sequences P and Z proves N_value<=H_value. This is stronger than
the independent operand bit capacities and is checked before division. The
divider returns full quotient/remainder. RNE compares twice the remainder
to the full denominator and increments for greater-than-half or half with
odd quotient. Rounded values above65536 or divider failures are fatal ARITH,
not clipped measurements. Zero U/V retains the exact raw statistics and
produces a separate undefined-ratio status; it never invokes division.

The multiplier has A_W=U and B_W=B; all operands fit these magnitudes,
including V<=B. Let `C=ceil((U+B)/8)` and `Lm=B+C`. From a multiplier
handshake its result becomes valid after Lm clocks. Core scheduling uses
one further consumption edge and the next request edge, so multiplier
request spacing is Lm+2.

Each triple executes twelve products: four for XY, four for XY*Conj(Z),
two XY energy squares, two Z energy squares. The final batch performs
Br^2, Bi^2 and U*V. On an accepted core sample edge0:

```text
next core input opportunity after a nonfinal triple = 12*(Lm+2)+1
zero-energy final result first valid                = 12*(Lm+2)+1
nonzero final result first valid                    = 15*(Lm+2)+W+3
```

The latter includes final accumulation, normalization setup, all final
products, divider request/iteration and result consumption once each.
With K samples and always-valid input/ready output, command-to-command
spacing is `(K-1)*[12*(Lm+2)+1] + [15*(Lm+2)+W+3] +3` for nonzero energy.
This is the sustained single-core batch service interval, not first latency.

Defaults D12/MAX64 give B44/U57/V31/N89/H88/W105, multiplier57x44,
C13/Lm57. Sample service interval709 clocks, nonzero final first-valid993
clocks, zero-energy709 clocks; K64 command interval45663 clocks. Maximum
D16/MAX256 gives B58/U75/V41/W133, multiplier75x58, Lm75; intervals925 and
1291 clocks. These are structural schedules and prospective TB checks,
not measured frequency claims. Input gaps and unbounded output backpressure
add waiting; no unconditional completion deadline follows.

The frame adapter stores three complex bins forming its pending triple, with no
frame RAM. It may collect a following spectrum while the core computes;
afterward it stalls at SEND. With continuous input, core-triple spacing is
max(BINS+1, core sample service interval), after the initial BINS+1 clocks.
The final measurement still uses the core's same post-triple schedule.

There is no inferred sample RAM payload to reset. The multiplier holds four
byte-padded (U+B)-bit vectors plus its B-bit shifting operand; the divider
holds three W-bit arithmetic vectors and quotient/remainder outputs. Core
registers retain the six input lanes, exact XY/triple/power temporaries,
four sums, final numerator/denominator and one result record. Counters use
clog2(MAX_AVERAGES+1), and op/state fields are4 bits. Defaults declare1113
core state/result bits,571 multiplier state/result bits and536 divider
state/result bits:2220 bits total before optimization. The default frame
adapter adds103 bits. This count includes helper output holding registers;
it is a declared-bit budget, not an inferred or measured FPGA FF count.
These are logical
storage roles; synthesis may map or optimize them differently. The likely
critical paths are the shared operand mux, final wide comparison and
restoring remainder subtract, not a twelve-multiplier combinational chain.

No target-specific primitives, keep attributes, speculative low-bit removal,
false/multicycle constraints or physical resource guarantees are introduced.
