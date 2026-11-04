# Exact bounded-denominator rational approximation

Baseline `ff2aadf8ebdc8e5475b7022cd68d47e496b9f593`. New numerical ratio-planning
capability for composing rational resamplers, clock-enable dividers or other
rational datapaths. This core itself neither filters samples nor generates
clocks. Actual finite qualification status and unabridged child records are
in `verification.json`; no synthesis, PnR, STA, device mapping or board test.
Always **HW_UNVERIFIED**. Logical resource risk LOW at default and maximum;
this is structural judgment, not measured PPA.

## Contract

Parameters: signed numerator width `W=2..16` (default 8), unsigned input
denominator of the same W bits, unsigned runtime limit width `QW=1..8`
(default 4), `TAG_W=1..32` (default 8). Every input bit is checked/used at
its declared width. For `D>0,Q>0`, return the unique canonical coprime `p/q`
minimizing `|N/D-p/q|` over all integers p and `1<=q<=Q`. Ties choose smaller
q, then smaller `|p|`; in particular positive/negative half integers at Q=1
round towards zero. Sign is symmetric and zero is always `0/1`.

`m_num` is signed `W+QW+1` bits; `m_den` unsigned QW bits. `m_error` is
signed `W+1` bits and is the **exact original-input residual**
`e=N*q-p*D`, including unreduced input ratios. Thus signed approximation
error is `e/(D*q)`, and exactness is `e==0`. Valid results obey `|e|<D`.
There is no floating tolerance, sample residual norm or estimated error.
Status bit0 denotes D=0; bit1 denotes Q=0, independently. For status!=0,
num/den/error are canonical zero, tag is preserved. Invalid input creates
one response and performs no numerical work. Numerator may be any signed
value including signed minimum; D and Q include their full unsigned maxima.

One clock, synchronous high reset, no CE or CDC. Ordinary `valid&&ready`
handshakes on rising edges. A single command owns the core until its response
is accepted; no other input is accepted meanwhile. The producer holds all
input fields while stalled. All output fields stay stable under backpressure.
Tag is captured with the command. Reset immediately gates ready/valid low
and the next rising edge cancels the owner; a fresh command starts from clean
control and fully initialized arithmetic state. No previous result survives.
No external memory and no configuration updates outside the accepted token.
The core returns to IDLE on response acceptance, so the next command is
accepted no earlier than the following rising edge. Backpressure may be
unbounded and is excluded from the calculation latency bound.

## Architecture, proof and budget

First compute `|N|=a*D+r` with W restoring-divider steps. For `0<r<D`,
start fractional bounds L=0/1, R=1/1 and exact positive residuals
`EL=r*Ld-Ln*D=r`, `ER=Rn*D-r*Rd=D-r`. Adjacent bounds satisfy
`Rn*Ld-Ln*Rd=1`. The mediant residual is `EL-ER`, so a search step needs
only numerator/denominator addition and W-bit residual subtraction. The
target remains enclosed and adjacency survives replacing either bound.
An equal residual yields the exact reduced mediant. Once `Ld+Rd>Q`, no
fraction strictly between these adjacent bounds can have denominator <=Q;
therefore a closest allowed value must be one of the two bounds. Compare
`EL*Rd` and `ER*Ld`, break ties by denominator then lower fractional bound,
and restore the sign. Adjacency also proves coprimality after adding a*q.

One unsigned shift-add multiplier is physically shared by these two W-by-QW
cross products and the final `a*q`; it takes exactly QW steps each. Exact
paths use only the final product. There is no data `*`, `/`, `%`, combinational
divider, RAM, ROM, coefficient table, DSP primitive or parallel unrolled
search. The denominator sum increases by at least one per update, so there
are at most Q-1 updates and Q search visits. All stored bound denominators
are <=Q, and numerators lie between zero and their denominators. Residuals
stay strictly below D. Products fit `MW=W+QW` bits; `a*q+fractional_num`
is less than `2**MW`, and its sign needs the extra output bit. Signed minimum
is converted to an unsigned W-bit magnitude before arithmetic.

Latency counts rising-edge intervals from accepted input to the first
post-edge assertion of m_valid (zero for invalid input). Integer exact path
is `W+QW+2`. With C search visits, exact-mediant path is `W+C+QW+2`;
two-bound comparison path is `W+C+3*QW+5`. Conservative valid bound is
`W+(2**QW-1)+3*QW+5`: default 40, maximum 300 intervals. Q=runtime value
can replace `(2**QW-1)` for a tighter transaction bound. No frequency or
wall-clock guarantee follows from these cycle counts.

All state and arithmetic are scalar registers. The exact declaration budget
is `13W+14QW+clog2(W)+max(1,clog2(QW))+TAG_W+12` bits (clog2(W)>=1),
default 185 bits and maximum 371 bits; zero RAM bits. This includes held
outputs, tag, limit, eight-state control, both multiplier result/accumulator
and the comparison register. W+1-bit divider compare/subtract, W-bit bound
compare/subtract, QW+1-bit mediant adds and MW-bit multiplier add are separate
scheduled paths; physical LUT/FF/DSP, Fmax and power are unmeasured.

## Frozen finite verification

`run_tests.py --freeze` writes fixtures and `TEST_PLAN.json` before any HDL
tool. `--run` verifies every frozen source/fixture hash and executes precisely
the listed matrix with subprocess timeout 20 seconds per child. TIMEOUT is
terminal: no retry, shrink or larger limit. Ordinary failure stops and saves
the original receipt; any authorized repair must preserve that history and
the exact frozen numerical matrix. No inherited configuration is rerun.

Six `(W,QW,TAG_W)` profiles: (2,1,1), (3,2,3), (4,3,8), (8,4,8), (12,6,8),
(16,8,32). First three exhaust every N,D,Q bit pattern, including all errors;
last three use a fixed boundary Cartesian product plus seeded vectors.
All use the full tag width. The oracle enumerates every q and floor/ceil
integer p from the original signed input, selecting exact Fraction error,
q and |p|. It independently verifies original-input residual and gcd.
Additional trace checks verify each divider result, adjacent-bound enclosure,
each complete shared multiply and exact work-based latency. The analytic
worst case `N=1,D=max,Q=max` reaches the configured bound.

The BFM checks all input/output fields while held, queues the actual next
frozen token until acceptance, and compares every response. Nineteen immediate
reset probes per profile target idle, first/last divider steps, INIT, SEARCH,
first/last steps of each of three multiply operations, their PRODUCT states,
CHOOSE, held success and each of three held error statuses. At the observed
falling edge reset is asserted with no intervening active edge. Each probe
then completes an analytic signed +/-1 fresh response with distinct tag and
backpressure. Duplicate first/last targets for QW=1 are deliberately retained.
These finite probes are not formal or hardware proof.

Offline use: `files.f` lists the core; `example/files.f` adds the complete
16-bit ratio-planning instance `rate_ratio16`. Fixtures and Python are test
inputs only. Root LICENSE/NOTICE apply; [SOURCES.md](SOURCES.md) records the
fixed upstream reading and semantic deduplication.
