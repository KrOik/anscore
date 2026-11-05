# Source architecture budget, unmeasured

K=N-1, SW=W+ceil(log2 N), IW=ceil(log2 N).

| Payload | Formula | N8/W16 | N12/W24 |
|---|---|---:|---:|
| DP score/valid/parent bank | K*2^K*(SW+1+IW) |20608|743424|
| Directed edge present/weight bank | N*N*(W+1) |1088|3600|
| Packed reconstructed tour | (N+1)*IW |27|52|
| Total logical payload bits | Sum of the above |21723|747076|

Read-q, scalar arithmetic, tag, address, scan, valid and FSM registers are
additional. There are two separate synchronous read-or-write banks, each
without a bulk reset loop. Mask0 DP rows are allocated but unused. Included
endpoints are overwritten for increasing masks before any read in this owner.
Edge presence is cleared explicitly before input admission. Constant address
products use fixed N/K; no variable multiplication datapath is specified.

One signed SW+1 adder, one registered candidate and one signed comparator are
shared across transitions and closing candidates. Parent reconstruction uses
the DP bank after scoring is complete. No request for peak throughput justifies
replicated transition lanes or extra RAM ports. No clock-rate claim is made.

The exact ENTRY/PRED_SCAN/PAIR_READ/PAIR_SUM/PAIR_COMPARE/COMMIT schedule uses
at most4K clocks for any (mask,node) slot; skipped endpoints use one clock.
Singleton slots use4. Closing uses4K+1, traceback2K, outputN+1 transfers.
For T accepted input beats with continuously asserted input and output ready,
the conservative full-owner budget, including initialization and capture, is:

    N*N + T + 4*K*K*(2^K-1) + 8*K + N + 16 clocks.

This gives25036+T at the default and991008+T at the maximum. Extra reset clocks
are excluded. Arbitrary input pauses and output backpressure have no bounded
completion time. This is an FSM counting argument, not measured performance.

Default architectural risk MEDIUM, maximum HIGH because storage/work grow
exponentially. Actual BRAM packing, LUT/FF/DSP mapping, area, Fmax, power,
timing and device fit are UNKNOWN. No synthesis, PnR, STA or hardware run.
