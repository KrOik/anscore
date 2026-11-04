# Exact integer characteristic polynomial

Computes the complete exact polynomial `det(lambda*I-A)` of an arbitrary runtime signed integer square matrix. Output order is `c0=1,c1,...,cN` in `lambda^N+c1*lambda^(N-1)+...+cN`. No floating point, quantization, modulus, division, symmetry restriction, or saturation applies to a legal result.

Status: **HW_UNVERIFIED**. Logical architecture and finite unit simulation are distinct from synthesis, placement/routing, timing closure, power measurement, and board evidence. The qualification receipt is `verification.json`; this source document makes no physical implementation claim.

## Parameters and interface

| Parameter | Default | Legal range |
|---|---:|---:|
| N | 4 | 1..8 |
| DATA_W | 8 | 2..12 |
| TAG_W | 8 | 1..32 |

Derived signed widths, with `L=ceil(log2(N))`, are `WORK_W=N*(DATA_W-1)+(N+1)*L+3` and `COEFF_W=N*(DATA_W-1)+ceil(log2(N!+1))+1`. Default widths are 41/34; maximum widths are 118/105. In particular N1 can represent the positive negation of the minimum negative input.

Accept `s_data` on `s_valid && s_ready`, with exactly N*N kept scalars in row-major order. `s_keep=0` ignores the data payload; accepted `s_last` and `s_bad` remain active. LAST closes the frame, including a masked LAST after the final kept scalar. The first accepted beat snapshots `s_tag`, including a leading masked beat. Later tags are ignored. A missing LAST keeps the capture owner active indefinitely; no timeout is invented.

The count saturates at N*N+1; kept overflow data never overwrites the matrix. Errors are sticky `m_errors[0]=SHORT`, `[1]=OVERFLOW`, `[2]=UPSTREAM`. SHORT is determined at LAST. Every accepted bad beat, including masked beats, sets UPSTREAM. Capture drains through LAST before responding.

A successful response has N+1 beats: signed `m_coeff`, `m_index=0..N`, `m_keep=1`, `m_last=(m_index==N)`, `m_errors=0`, and the first tag. An erroneous frame produces exactly one beat with zero coefficient/index, keep0, LAST1, and the sticky errors/tag. All response fields remain stable during backpressure.

One owner spans capture, compute and output. There is no input acceptance while computing or emitting, and no input fallthrough on the final response retirement edge. Synchronous active-high reset immediately gates `s_ready` and `m_valid`, cancels partial input/computation/output, and clears control at its rising edge. Payload RAM and read-q registers are intentionally unreset; every later read has a fresh ownership/write proof.

`example/charpoly4.sv` exposes the default 4x4, signed 8-bit service with five signed 34-bit output coefficients. File lists are relative to this package root.

## Architecture and arithmetic proof

Iterative Berkowitz processes trailing principal submatrices of size m=1..N. Size1 directly writes `[1,-a]`. At m>=2, partition `M=[a R; C B]`, let d=m-1, and form only the Toeplitz first column `g=[1,-a,-R*C,-R*B*C,...]`. Two vector banks generate `B^t*C`; two coefficient banks hold the previous and next complete polynomials. Each new coefficient is the serial convolution `p_i=sum_j g_(i-j)*q_j`. No full Toeplitz matrix or recursion stack is stored.

Set `X=2^(DATA_W-1)`. A full signed vector product is bounded by `d^t*X^(t+2)` and every dot prefix by `d^(t+1)*X^(t+2)`, since `|B^t*C|<=d^t*X^(t+1)`. Thus `|g_r|<=d^(r-1)*X^r` for r>=2. Previous coefficients satisfy `|q_j|<=d!/(d-j)!*X^j<=d^j*X^j`. Each full signed convolution product for p_i is at most `d^i*X^i`; every accumulation prefix is at most `m*d^i*X^i<=Q=N^(N+1)*X^N<=2^(WORK_W-3)`. These bounds apply before cancellation.

Completed coefficients obey the separate principal-minor bound `|c_i|<=choose(N,i)*i!*X^i<=N!*X^N`; only the completed coefficient narrows to COEFF_W. Every absolute value and sign restoration is strictly inside its signed range, including input extrema.

One explicit shared shift/add engine operates on **WORK_W x COEFF_W** magnitudes: DATA_W steps for DATA_W x WORK_W vector products and COEFF_W steps for convolution. True default operand widths are 8x41 and 34x41; maximum widths are 12x118 and 105x118. No general data multiplier or divider is inferred from the production source. One WORK adder is explicitly multiplexed between multiplication accumulation and dot/convolution accumulation, with one WORK and one COEFF unary sign/magnitude path.

For a magnitude product a*b<=Q, partial shift/add sums are nonnegative subsets of the full product. While the remaining factor is nonzero, its highest pending bit h>=t proves `a*2^t<=a*2^h<=a*b<=Q`. The shift register freezes after the last nonzero factor bit; fixed cycles continue consuming zeros. No significant upper product bits are discarded before this proof applies. A generic WORK_W+COEFF_W product register is therefore unnecessary.

## Storage and schedule

Six single-port synchronous banks contain A (`N*N*DATA_W`), two V (`2*N*WORK_W`), G (`(N+1)*WORK_W`) and two Q (`2*(N+1)*COEFF_W`). Each bank performs one enabled read OR write per cycle. Capture writes only A. Base/diagonal phases read A while writing Q/G. Vector phases read A and one V source, then write G or the other V bank. Convolution reads G and Q source, then writes Q destination. Output reads the final Q; held output performs no memory operation. V/Q ownership swaps only after complete destination writes; G is complete before convolution.

| Logical budget | Default N4/W8/T8 | Maximum N8/W12/T8 |
|---|---:|---:|
| Payload RAM bits | 1,001 | 5,608 |
| Declared scalar register bits, including every RAM read-q | 399 | 1,085 |
| Narrow products | 36 | 784 |
| Wide products | 28 | 154 |
| Multiply bit steps | 1,240 | 25,578 |
| Compute clocks after accepted LAST | 1,452 | 28,464 |
| All outputs retired with continuous ready | 1,462 | 28,482 |

Let `Pn=(N*(N-1)/2)^2`, `Pw=N*(N+1)*(N+5)/6-2`. Fixed compute work is `C=N*(N+1)+Pn*(DATA_W+3)+Pw*(COEFF_W+3)`. Each product uses READ, LOAD, fixed bit steps, ACC. First valid is asserted after C+1 subsequent clocks; the first continuously-ready handshake occurs at C+2. With FETCH/HOLD for each output, the final handshake is at `C+2*(N+1)`. N1 has C=2 and final retirement at 6. Backpressure adds only HOLD clocks. Error valid appears immediately after the accepted LAST edge.

The exact scalar ledger is in COST.md. Six small wide banks may map to LUTRAM/flops or waste BRAM capacity through fragmentation. A 118-bit sign/adder path has no measured frequency claim. Resource labels are qualitative LOW at default and MEDIUM at maximum, subject to mapping; these are not utilization reports.

## Frozen qualification

Before any child execution, the first source seal (`69b316c517213105f3abe8aae54a0f2daf9cbbe745302b15f9f2cec847b6b461`) was archived verbatim under `.git/anscore-b25-b-prehdl-seal-01`. Root authorized scalar temporary destinations for fixture `$fscanf` compatibility and this history note, then a replacement seal. No child ran under the superseded seal; RTL, fixture fields/order, all706 fixtures, the immutable plan/369 children, runner and20-second limits were unchanged.

Attempt01 under seal `20e517d94ea43aa047446f58da19d0ab216ab1dda446c073a33239d53c144d9f` stopped at child6 `p0_main_000`, time0, with `trailing fixture bytes`; five children passed and363 remained NOT_RUN, without timeout. Its complete724-file archive retains the exact sources, receipt and compiled artifact. Root independently parsed all353 text fixtures with no remaining token. The actual final `$fscanf` return value was not logged; an EOF-return classification issue is a hypothesis. Root authorized only an explicit `$fgetc` tail scan that accepts ASCII space/tab/CR/LF and rejects every other trailing byte, runner archive guards and a single attempt02 gate, plus this history. The fixture grammar, DUT, oracle, complete369-command matrix, splits and20-second limit remain unchanged. `REPAIR_RECORD.json` and the new seal bind the retained failure to the explicitly authorized repair; there is no automatic retry.

`TEST_PLAN.json` was frozen before original RTL. Its SHA256 is `9a2cd0dd9a32b77524ef8234a90a9ea072ced9f9a94d40da15cee240c15013bd`. It contains the entire immutable 369-child order, six legal parameter profiles, six invalid-parameter children, 168 main frames, 290 reset/fresh sequences, and exact JSON/text fixture hashes. Maximum N8 main jobs contain exactly one complete frame and have no internal cross-frame acceptance claim. Smaller main jobs provide 105 actual queued transitions.

The independent primary oracle expands all principal minors by signed permutations. The second oracle computes full integer matrix powers by binary exponentiation and uses Fraction Newton identities. Every coefficient agrees, and the full Cayley-Hamilton matrix certificate is zero. Trailing polynomials use the same independent principal-minor oracle; G and vector certificates come from full matrix powers rather than the DUT vector control flow. No SymPy code is imported or executed.

Reset predicates cover all 19 planned states, narrow/wide multiplication first/middle/last bits, vector/coefficient bank swaps on both sides, signed accumulation prefixes, first/interior/final outputs and retired prefixes, five error summaries, and actual next-frame first beats blocked during computation/output. N1 and N2 unreachable targets are explicitly excluded, never aliased. Each reset offers valid traffic for three reset-high clocks, checks immediate gating and zero acceptance, then checks one complete fresh frame and all N+1 output coefficients.

The TB checks every issued read's ownership and synchronous data, every relevant RAM write, every signed dot/convolution prefix, multiplication magnitudes/partial sums/shift safety, result/tag/error/keep/LAST, source and output stability, exact first-valid latency, and post-reset purge.

Commands from this package root:

```
python -B run_tests.py --seal
# Root performs read-only preflight of SOURCE_FREEZE.json before first HDL.
python -B run_tests.py --run
python -B run_tests.py --check
```

An archived ordinary failure may use `--repair-seal` only for the specifically root-authorized attempt01 EOF repair. This validates the original archive and hashes, refuses a second repair record, replaces the already-archived current receipt/seal, and creates the new seal. Root must review that seal before `--run`; an existing attempt02 receipt blocks rerunning it.

The source seal includes every source, document and fixture plus all fixed children. Every subprocess has a 20-second hard timeout with process-tree termination. TIMEOUT is terminal: no retry, splitting or workload reduction. An ordinary failed attempt archives exact sealed sources, complete fixtures, children, stdout/stderr, exit/time, receipt and artifacts, then stops for specific root repair authorization. `--check` reads evidence and hashes without executing HDL. No inherited matrix is rerun.
