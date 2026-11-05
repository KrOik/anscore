# Structural cost and service budget

Status: SOURCE_ONLY / NOT_RUN / HW_UNVERIFIED. No measured LUT, FF, DSP, BRAM, power, Fmax or placement/routing result exists.

For N samples, W input bits, C=ceil(log2(N+1)) and P=W+ceil(log2(N+4)), data storage is N*W input bits plus N*(P+C) packed result bits. This is 672 logical bits at N=16/W=16 and 3968 at N=64/W=24. Scalar bound/candidate/control/tag registers, one sample read word and one result output word are additional. Two banks each need only one scheduled synchronous read or write per edge; no read/write collision is consumed. No RAM initialization/reset sweep is required by the ownership proof.

The exact comparator sign-extends into R=P+C+2 bits and uses one shared add/subtract path over two C-cycle count products. Four comparisons per visited sample give at most 8C+10 visit clocks including read/bound formation. K emitted blocks give 2K transition clocks; writes total N; input captures N; result reads/retirements total 2N. Anchor progress gives K<=N and V<=N*(N+1)/2, hence the inclusive first-input through last-output edge budget

    T <= (8C+10)*V + 2K + 4N
      <= (8C+10)*N*(N+1)/2 + 6N.

That conservative structural bound is 6896 edges at the default and 137664 at N=64. It includes actual authored RAM read, comparator setup/result, restart, write and output states. The initial brief's 96-per-visit placeholder is replaced by this accounting. lambda=0 takes a direct per-sample branch but obeys the same bound. Missing valid inputs, output backpressure and reset are outside the always-ready frame bound. There is one-frame ownership and an output retirement interval of two clocks, not a continuous-input streaming pipeline.

Serialization suits the bounded N<=64 contract and avoids eight parallel cross-product operators. A faster linear-time stack method would need extra envelope storage, stack-port scheduling and a different correctness/cycle proof; it is not part of this implementation. Mapping the narrow count products to device DSP could reduce cycles at a resource cost, but no such variant is included. An intended inference shape is not a physical resource measurement.

Architecture risk: MEDIUM. Correctness depends on exact wall witnesses and restart boundaries, signed cross-product handling, and dominance of RAM writes over later reads. Timing risk includes the R-bit shared add/subtract path and the P-bit bound offset path. No target clock is guaranteed before tool evidence. See MATHEMATICS.md for every range and state charge.
