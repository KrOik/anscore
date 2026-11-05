# Exact 1-D TV mathematics and state accounting

Status: SOURCE_ONLY_MATHEMATICAL_DERIVATION; preparation/oracle/HDL/checker/synthesis/PnR/STA/board execution NOT_RUN. Hardware HW_UNVERIFIED. This derivation was written before the RTL and has since been matched statically to `rtl/exact_1d_tv_denoise.sv`; no RTL tool has run. It develops a sequential scan of feasible cumulative-path slopes from the objective and KKT conditions; it does not translate either CeCILL C source. The reviewed finite-case brief is `.git/b29-b-candidate-brief.md`, SHA256 `6230f5067b5b54b84e6c8222af9ef86aaf351d082d36ce6f670ed45f2579de38`.

## Objective, sign convention and sufficiency

For signed integer samples x[0..N-1] and nonnegative integer lambda, minimize

    F(y) = (1/2) sum_i (y[i]-x[i])^2 + lambda sum_(k=1..N-1) |y[k]-y[k-1]|.

The quadratic term is strictly convex, so the minimizer is unique. Define q[0]=q[N]=0 and

    q[k] = sum_(i=0..k-1) (y[i]-x[i]).

An exact candidate is optimal if and only if every internal q[k] is in [-lambda,+lambda], with q[k]=+lambda at an upward fitted jump and q[k]=-lambda at a downward fitted jump. At a flat edge either endpoint of the dual interval is legal. To see the sign, choose t[k] in the subgradient of |y[k]-y[k-1]|. Stationarity at sample i is y[i]-x[i] + lambda*(t[i]-t[i+1])=0, taking the external t[0]=t[N]=0 with edge indexing shifted to match q. Equivalently y[i]-x[i]=q[i+1]-q[i] and q[k]=lambda*t[k]. Summing gives the q formula, feasibility gives the subgradient bound, and the nonzero-jump sign gives complementarity. Convex stationarity is sufficient. No rounded objective comparison is needed.

Let X[k]=sum_(i<k)x[i] and Y[k]=sum_(i<k)y[i]. The same conditions say that Y lies in the tube X[k]-lambda <= Y[k] <= X[k]+lambda at internal cumulative nodes, has fixed endpoints Y[0]=0 and Y[N]=X[N], and can increase its slope only at the upper tube wall or decrease it only at the lower wall. A flat continuation at a wall remains legal.

## Exact construction from one fixed anchor

An emitted prefix ends at cumulative index a, with Y[a]=X[a]+q_a. Initially a=0 and q_a=0. At a nonterminal emitted boundary q_a is either +lambda or -lambda. Scan one input sample at a time starting at a. For a scanned cumulative endpoint k>a, store D=k-a and S=sum_(i=a..k-1)x[i]. A proposed constant next level v is feasible through that node exactly when

    L(k)=(S-lambda-q_a)/D <= v <= U(k)=(S+lambda-q_a)/D,  k<N.

At k=N replace both bounds by the same exact endpoint slope

    E=(S-q_a)/D.

Maintain the maximum lower slope l and minimum upper slope u over the scanned nodes, with positive denominators and the cumulative node attaining each bound. Until a conflict, l<=u. Equal new bounds replace the stored witness with the latest attaining node; strict comparisons alone decide conflicts.

On a new lower slope L(k)>u, emit v=u from a up to the previously stored upper-bound witness j. The witness is strictly before k. It has q[j]=+lambda. Restart from a=j with q_a=+lambda; unread/rejected lookahead is rescanned from the stored input samples.

On a new upper slope U(k)<l, emit v=l up to the previously stored lower-bound witness j, giving q[j]=-lambda. Restart from a=j with q_a=-lambda.

Otherwise tighten l and u and continue. If the endpoint k=N is reached without conflict, the endpoint value E is inside the preceding feasible interval; emit it through N and finish.

For lambda=0, a direct explicit branch emits each stored x sample with denominator one and q=0; it avoids an otherwise valid unreduced constant-block encoding that would violate the requested denominator-one passthrough representation. N=1 with any lambda follows the ordinary exact endpoint rule and also has denominator one.

## Why each emitted prefix is feasible

Before a conflict, u is at least every scanned lower bound and at most every scanned upper bound; l has the same property. Therefore either chosen slope is feasible from a through its selected witness. The selected witness is an internal node j<k<=N, so its corresponding upper/lower tube-wall equality is exact. Advancing a to j always emits at least one sample.

A conflict must not cause an invalid jump at the new anchor. Consider an upward-forcing conflict L(k)>u and its upper witness j. Set v=u. For every earlier scanned node i with j<i<k, U(i)>=v. Subtracting the line value Y[j]=Y[a]+v*(j-a) from the upper-tube ordinate shows that every such upper slope measured from j is also >=v. At the forcing node k, the corresponding new-anchor lower slope is >v. During the restarted scan, if its first emitted prefix ends before k, an upper-witness emission has slope >=v, and a lower-witness emission can occur only above an upper bound that is itself >=v. If no prefix ends before k, the new running lower bound becomes >v, so the eventual first emitted or final suffix slope is >v. Thus the first level after j is never below v. The join is either flat or upward, exactly compatible with q[j]=+lambda.

The downward conflict is the symmetric argument: earlier lower slopes measured from its new anchor are <=v, the forcing upper slope is <v, and the first following level cannot exceed v. Its join is flat or downward, compatible with q[j]=-lambda.

Induction establishes tube feasibility and the correct sign at every emitted join. The final suffix enforces q[N]=0. These are precisely the sufficient KKT conditions above, so the complete emitted vector is the unique optimum. This proof permits equal-level neighboring emitted blocks; no merge or fraction reduction is required.

## Integer representation and bounds

Write M=2^(W-1), so -M<=x<=M-1 and 0<=lambda<=2M-1. Let

    C=ceil(log2(N+1)), I=max(1,ceil(log2(N))),
    P=W+ceil(log2(N+4)), R=P+C+2.

All cumulative endpoints/counts are unsigned C bits, including the exact value N. RAM addresses can use I bits; the source keeps a C-bit scan/write endpoint counter and consume it only while <N. The comparison bit counter requires max(1,ceil(log2(C))) bits, with legal states 0..C-1. Bound denominators are always 1..N, never zero.

For every scanned segment of length D<=N,

    -D*M <= S <= D*(M-1).

Every nonterminal bound numerator is S + c*lambda with c in {-2,-1,0,+1,+2}; the terminal numerator has c in {-1,0,+1}. Therefore

    -(N+4)*M < numerator < (N+4)*M <= 2^(P-1).

A signed P-bit register covers each segment sum, candidate bound, stored bound and emitted numerator. Negative minimum samples are sign-extended before addition, never negated in W bits. Penalty is zero-extended from unsigned W bits into signed P bits before a shift, add or subtraction. Its possible twofold offset fits P bits. The left-wall state can be a signed two-bit sign code -1/0/+1, rather than a wide mutable dual value.

A comparison of a/d_a and b/d_b uses Delta=a*d_b-b*d_a. Each |product|<2^(P-1)*N<2^(P+C-1), and |Delta|<2^P*N<2^(P+C). Signed P+C+1 bits would suffice for the difference under these domain bounds; R=P+C+2 leaves an additional bit and is retained for clear shared-operator scheduling.

The shared comparison engine sign-extends both P-bit numerators into R bits first. Over C clocks it accumulates the first numerator times the opposite unsigned denominator using a left-shifting signed R-bit operand and a right-shifting unsigned C-bit factor. Over a second C clocks it subtracts the second product in the same accumulator. Partial first-product sums have magnitude no larger than that complete product. During subtraction, partial differences are bounded by the sum of the two product magnitudes, below 2^(P+C); R covers every intermediate, not only the final sign. No division, modulo, floating point, tolerance, saturation or result wraparound is used.

Default N=16/W=16: P=21,C=5,R=28. Maximum N=64/W=24: P=31,C=7,R=40. Output denominator width is C, output numerator width P. Output equality is equality of rational values, because unreduced encodings of the same level are allowed.

## Chosen architecture and actual intended FSM accounting

Use one N*W synchronous input bank and one N*(P+C) synchronous packed result bank. Input capture and input solving reads occur in disjoint states. Result block writes and result output reads occur in disjoint states. Each bank needs only one scheduled read or write per edge; no same-address read/write collision behavior is consumed. The source controls RAM ownership, without resetting either array. After reset every input address is rewritten by the complete new frame before any solve read, and all N result addresses are written before any output read.

There is one shared R-bit add/subtract accumulator for the two products in each ratio comparison, not eight parallel multipliers. Ordinary P-bit sum/offset formation is separate from that engine. The source has no arithmetic multiplier or numeric divider in the compute datapath. Physical DSP/LUT/BRAM mapping and power/Fmax remain unmeasured.

The authored twelve-state schedule is matched to the following table (`ST_` is the literal RTL prefix). A cycle means an active edge spent in the named state; the inclusive first-input through final-output edge count is conservatively bounded.

|Stage/state|Edges charged|
|---|---:|
|CAPTURE|N accepted input edges; missing offered beats add external waiting|
|BLOCK_INIT|1 per emitted block|
|READ_SAMPLE|1 per sample visit; synchronous input read is captured at this edge|
|MAKE_BOUNDS|1 per visit; consumes the prior synchronous read|
|COMPARE_INIT, COMPARE_LEFT, COMPARE_RIGHT, COMPARE_DONE|1+C+C+1=2C+2 per ratio comparison|
|WRITE_BLOCK|1 per emitted output sample, N total|
|FINISH_BLOCK|1 per emitted block|
|OUTPUT_READ, OUTPUT_HOLD|1+1 per result with always-ready sink; held cycles add external waiting|

At most four comparisons are performed for an ordinary visited node: new lower versus old upper (up conflict), new upper versus old lower (down conflict), lower tightening and upper tightening. The first node of a block seeds bounds without comparisons. Conflicts stop the remaining comparisons. Thus the conservative charge per sample visit is

    2 + 4*(2C+2) = 8C+10.

Let K be the number of emitted blocks and V the sample visits. Since every block ends strictly after its anchor, K<=N. Every scan visits at most the remaining suffix length; strictly advancing anchors give

    V <= N+(N-1)+...+1 = N*(N+1)/2.

The two wall-witness endpoints and every restart are retained exactly; there is no uncounted nested search. Result writes total N, input captures N, and synchronous output read/retirement costs 2N. The two per-block states cost 2K. Therefore

    T <= (8C+10)*V + 2K + 4N
      <= (8C+10)*N*(N+1)/2 + 6N.

This includes all authored RAM read latency, comparison setup/result states, block transitions, result writes and output drain. It is 6,896 edges at N=16 (C=5) and 137,664 at N=64 (C=7); it is a conservative structural ceiling, not measured simulation latency or a guaranteed clock frequency. The earlier brief's larger 96-per-visit budget is superseded by this explicit state accounting after static confirmation of all twelve RTL states; there is no executed latency measurement. Any later FSM state or RAM latency change must update this derivation before qualification.

RAM data storage is N*W+N*(P+C): 672 logical bits at default and 3,968 maximum, excluding scalar registers, two synchronous read/output words and metadata. Tiny configurations may map to FF/LUTRAM and larger ones to device BRAM at different utilization; no physical count is promised.

The module admits no next frame before the final result handshake. It becomes ready on the following cycle, never on that same final retirement edge. Output read and hold states imply an always-ready retirement interval of two clocks per sample. All output fields and the captured tag remain stable while valid and not ready. Reset synchronously cancels capture/solve/held ownership and combinationally masks both ready/valid handshakes while asserted. Reset cancels a frame, not the mathematical solution of a later fresh frame.

## Independent finite evidence boundary

Retain only the ten named normal cases and four named reset intentions from the revised brief. The independent reference validates the fixed analytic y values using exact Fraction KKT residuals and jump signs. It does not implement this slope scan, enumerate sign partitions or search a space of inputs. Normal cases are associated with one specific profile and one specific schedule; no automatic cross product, mirrored cases, random samples or regression expansion is permitted.

Reset partial capture is tied to DEFAULT_TWO_PLATEAUS after three input handshakes. Reset envelope update is tied to FRACTIONAL_THREE after the lower-bound tightening phase of its second visited node. Reset jump finalization is tied to OPPOSITE_JUMPS after the first up-conflict has latched its output block. Reset held-final is tied to SINGLETON_MIN, before its only output is accepted and while a future frame is merely offered. These predicates are matched to the authored TB. Each aborted frame uses the bitwise complement of the named case tag within TAG_W; its fresh replay uses the original tag, without adding a mathematical input case. No unreachable N=1 capture/solve predicate is included.

Only after source freeze and independent review may root open a separate single preparation gate, followed by a separately sealed finite HDL gate. Source authoring alone does not establish certificate execution, syntax/lint/simulation success, timing closure or hardware validation.

## Provenance and evidence limitations

The objective and primary bibliographic attribution remain in the candidate brief. The author's CeCILL C files were previously read only for scope/license awareness; this note contains no copied source and no line-by-line algorithm translation. Its actual construction, sign proof and integer scheduling are derived above from the KKT/tube formulation. The author PDF has not been read; a fresh web open again failed with service HTTP500. No paper-specific theorem numbering or quotation is claimed. A later mathematical cross-review may challenge this written proof before any preparation or HDL, without relying on execution as a substitute for the proof.
