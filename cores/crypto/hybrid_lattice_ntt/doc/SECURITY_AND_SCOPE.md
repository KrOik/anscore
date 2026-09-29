# Security Scope For The Current NTT Milestone

The current RTL is a functional shared-operator 256-point NTT/INTT milestone
with a two-lane batched scheduler over even/odd synchronous coefficient banks
and a narrow operation scheduler boundary. The durable serial zero-DSP
comparator remains useful because it gives a concrete place to measure area,
timing, KEM/DSA mode sharing, and full-transform control reuse on Tang Primer
20K. The active operation-scheduled dual-bank head does not yet claim
side-channel resistance.

## Manual Lemmas Used By The Baseline

1. Modular double-and-add invariant:
   after bit `i`, `acc = b * (twiddle mod 2^i) mod q` and
   `multiplicand = b * 2^i mod q`.

2. Butterfly correctness:
   after all 23 bits are consumed, `product_mod = b * twiddle mod q`; therefore
   the outputs satisfy `y0 = a + product_mod mod q` and
   `y1 = a - product_mod mod q`. In inverse mode the same multiplier computes
   `y0 = a + b mod q` and `y1 = (a - b) * twiddle mod q`.

3. Fusion boundary:
   KEM and DSA differ only in `q`. The multiplier, adder/subtractor, control
   states, and output formulas are shared.

4. NTT/INTT dataflow:
   for each stage `m = 1, 2, ..., 128`, the core applies the same butterfly
   operator to `(a[j], a[j+m])` with the stage-local twiddle selected from a
   precomputed flattened table indexed by `m - 1 + j`. The active two-lane
   scheduler batches adjacent independent butterflies when `j + 1 < m`, keeps
   stage `m = 1` single-lane, and maps adjacent coefficients across even/odd
   synchronous banks so paired reads and writes can proceed in parallel. The
   INTT slot traverses the inverse GS schedule and applies a final `n^-1`
   scaling pass.

5. Digest check:
   the on-board self-test does not expose all 256 coefficients. It checks a
   deterministic digest of the full KEM transform, a deterministic digest of
   the full DSA transform, deterministic digests for the KEM/DSA INTT slots,
   their legacy combined NTT report digest, and a compact OPS4 aggregate digest
   for the four transform slots.

6. Operation boundary:
   the current scheduler implements `KEM_NTT`, `DSA_NTT`, `KEM_INTT`,
   `DSA_INTT`, bounded `KEM_FLOW`, and bounded `DSA_FLOW`. The bounded flow
   skeletons sequence NTT then INTT and return deterministic aggregate digests;
   `HYBRID_RUN` and broader future flow opcodes remain explicit non-operations
   that return `done/error` until implemented.

## Explicit Non-Claims

- No second-order masking is implemented yet.
- No global control-flow randomization is implemented yet.
- No glitch-extended probing proof is complete yet.
- No TVLA measurement has been taken from this design yet.
- No CHES/TCHES comparison table has been validated yet.
- No complete top-level ML-KEM/ML-DSA flow is implemented yet. The bounded
  `KEM_FLOW` / `DSA_FLOW` scheduler skeleton only sequences existing transform
  slots and returns aggregate digests in simulation. The board-visible `OPS4`
  report makes KEM/DSA NTT and KEM/DSA INTT transform slots observable, but it
  is not a complete KEM/DSA primitive or board-visible flow report.
- The current implementation is still a bounded batched NTT milestone, not the
  zero-switch-overhead systolic NTT architecture required for the final
  throughput claim.

These are the next gates before the project can satisfy the full research
objective.
