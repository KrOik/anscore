# Exact cycles and bounded storage (source derivation only)

All latency origins are the rising edge accepting the final source pixel.
First-valid is the first settled half-cycle in which valid is visible; a
successful always-ready transfer occurs on the following rising edge. Let

```
N = W*H
R4 = 2H(W-1)+2W(H-1)
R8 = R4+4(W-1)(H-1)
```

R is directed grid degree sum and K is4 or8. Let Hwork count the dependency's
z-read edges (child states18 or20), A count new T_READ visits, B count new
PP_READ visits (canonical nonroot nodes), E count LOSE_READ visits (gray-gap1
pairs), and F count first filter products (MUL purpose2,step0).

The child max-tree final-input to first-valid latency is

```
Ltree = 3*256+(20+2K)*N+W*H*(H-1)/2+2R+2Hwork+3
```

Its successful record cadence is4. First child transfer is Ltree+1 edges from
the origin; the Nth child transfer collected by this wrapper is Ltree+4N-3.
From there, variation costs3N+2A, pair cancellation2N+2B+22E, filtering3N+20F,
and the first node replay2. Hence the exact successful first-valid latency is

```
L = Ltree+12N+2A+2B+22E+20F-1
```

Successful replay II is3 and the final always-ready transfer is L+3N-2.
Error first-valid latency is N+1 and replay II1; Hwork=A=B=E=F=0 on that bypass.
An output stall delays retirement directly and does not alter first-valid.

Every undirected grid edge can cause at most N ancestor z reads:
Hwork<=R*N/2. A never revisits a strict ancestor on one node's path, so its total
is at most the number of strict ancestor pairs, N(N-1)/2. Also0<=B,E,F<=N-1
and E<=B. Substitution gives these independent safe maxima:

| Profile | R | Ltree bound | L bound | Final transfer, always ready |
|---|---:|---:|---:|---:|
| Default8x8/K4 |224|17571|25142|25332|
| Maximum16x16/K8 |1860|491787|571358|572124|

The TB holds every scored result for two cycles, adds a deterministic one-cycle
source bubble before indices with i%5==2, and maintains a true next-frame offer.
A maximum complete frame from first input is at most572942 clock edges; the
maximum fixed two-frame main group is below1.15 million paper edges. The
default group with8 reset probes and8 fresh frames is below0.409 million paper
edges using a full-frame bound for each cancelled probe. Maximum reset8 uses
one max probe plus one max fresh frame. These counts justify finite grouping;
they make no wall-clock20s PASS prediction. A future process tree timeout is a
terminal failure even when the paper count is valid.

New node RAM bits are N*(10+IW+2CW):1920 at8x8,9216 at16x16. Including the
unchanged child's source-level memories yields5888/default and22272/maximum
bits. Scalar, output, saved-word and RAM-read registers are additional. One
shared9x9 iterative multiply replaces all new runtime products; there are no
new ROMs or dividers. No synthesis, mapped RAM count, LUT/DSP count, Fmax,
power, PnR, STA or board result has been measured or claimed.
