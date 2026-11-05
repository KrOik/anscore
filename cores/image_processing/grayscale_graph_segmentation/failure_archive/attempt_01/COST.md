# Source-declaration storage and bounded schedule

These are exact logical declarations and conservative clock-count bounds.
No synthesis, mapping, PnR, STA, power, board or wall-clock performance result
exists. RTL/tool/oracle execution is NOT_RUN in the author draft.

Let N=W*H, E=H*(W-1)+W*(H-1), I=max(1,clog2(N)), C=max(1,clog2(N+1)),
X=max(1,clog2(W)), Y=max(1,clog2(H)), Q=max(1,clog2(E+1)),
J=max(1,clog2(E)), R=1 when clog2(N)<2, otherwise clog2(clog2(N)+1).
M=C+8+I, B=I+9 and P=max(16,C+8). The inherited DSU uses tag width1.
E=0 still declares a one-entry edge bank and256 one-bit histogram entries;
these are counted even though the singleton path bypasses them.

## Complete bank allocation

|Bank|Logical depth x width|16x16/T8|64x64/T32|
|---|---|---:|---:|
|Captured pixels|N x8|2048|32768|
|Stable sorted edges|max(1,E) x(I+1+8)|8160|169344|
|Counts, then exclusive-prefix cursors|256 x Q|2304|3328|
|Original DSU parent/rank|N x(I+R)|3072|65536|
|Root size/internal/minimum-label|N x(C+8+I)|6400|135168|
|Payload total||21984|406144|

An edge stores source index I, direction1 and exact weight8. Its destination
is derived from that legal direction, so no second endpoint table is allocated.
There is no unsorted edge bank, linked-list RAM, separate prefix bank or hidden
sort/index array. The graph is regenerated from the immutable pixel bank.
Address J is a slice of the full Q-bit cursor; cursor E is representable but
never used as an edge address. All generated destinations are below N.

The four new RAM read-q registers total8+B+Q+M bits:59/75. The DSU node_q
adds I+R:12/16. All read-q therefore totals **71/91 bits**. None resets.

## Every scalar storage declaration

Top storage excluding read-q and RAM is:

```text
state6
capture/init/scan/out indices4I
capture/scan/out x3X; scan yY
direction/scatter/post flags3
histogram index/source pixel/weight24
prefix sum and edge cursor2Q
held edgeB
two roots and returned write root3I
two captured component records2M
shared productP
frame K16; frame minimum/region count/area hold3C
label holdI; errors4; first tagT
= 53+8I+3X+Y+2Q+B+2M+P+3C+T
```

This is270/378 bits. The unchanged backend's scalar declarations are
`12+8I+4R+C` with its tag width1:101/137 bits. Combined scalar storage is
**371/515 bits**. Payload + read-q + all scalar declarations is therefore
**22426 /406750 bits**. Combinational addresses, product wires and arithmetic
carry wires are not storage. Actual technology may optimize or replicate banks;
these totals do not predict physical BRAM counts or FF mappings.

## Ports and lifecycle

- Pixels write only during accepted capture; after N inputs they are immutable.
  Each generated edge reads source and neighbor in separate READ/CAPTURE pairs.
- A histogram bin read precedes its sole update. First-pass counts are replaced
  by an exclusive prefix in256 READ/COMMIT pairs. In the second identical graph
  traversal, each original edge takes and increments its weight's next cursor.
  This gives a stable total order without a multiport sort memory.
- Sorted edges write only during scatter and read only after scatter completes.
  Each phase reads addresses0..E-1 exactly once.
- Component metadata initialization/read/write states are exclusive. Only live
  DSU roots are read; UNION's actual returned winner is the write address.
  Losing-root metadata becomes unreachable. Its stale payload need not clear.
- Backend parent/rank initialization, lookup and linking are already mutually
  exclusive. The wrapper performs no overlapping command and never relies on
  read-during-write behavior. No RAM uses a bulk reset or asynchronous read.

## Numeric bounds and operators

The exact difference is0..255. Component sizes and region counts lie1..N;
indices lie0..N-1. Disjoint unions have size_a+size_b<=N, so the C-bit stored
size cannot wrap. A C+1-bit temporary carries the sum. Internal difference
always lies0..255. Canonical labels are the minimum of real member indices.
First-pass bucket counts sum to E; prefix offsets and updated cursors lie0..E.
The Q-bit width includes E, including power-of-two edge counts.

The sole shared unsigned multiplication has8-bit gap and C-bit size inputs.
All C+8 product bits are retained, and the comparison register has at least16
bits to preserve every K input on small profiles. At64x64,
`255*4096=1044480`; truncating that product to16 bits would give61440 and can
reverse the predicate against65535. The maximum-half fixture tests the same
hazard with size2048. There is no division or rounded rational threshold.
Actual multiplier mapping may use a DSP; none is claimed or forced.

## Clock-count service bound

These bounds exclude input pauses, output waiting and reset cancellation.
They do not predict simulator wall time or hardware frequency. Let
D=floor(log2(N)), bounded by the unchanged union-by-rank backend.

Each of2N candidate edge slots takes2 clocks if out of bounds,8 if valid.
One graph traversal therefore costs6E+4N. Two traversals,256 histogram init
clocks,512 prefix clocks, N metadata init clocks and an N+2 backend CLEAR
command give **12E+10N+770** clocks before the first edge phase, for E>0.
The E=0 singleton path bypasses histograms/sorting and costs2N+2 clocks.

Each phase edge costs at most4D+28 clocks: two edge fetch states, two complete
FIND transactions, four metadata fetch states, at most three predicate states,
one UNION of already obtained roots, metadata commit and next-edge control.
At most two phases execute. Each output costs at most2D+7 clocks with ready1.
Thus a conservative E>0 post-capture completion bound is:

```text
12E+10N+770 + (1+(min_size>1))*E*(4D+28) + N*(2D+7)
```

The worst two-phase values are72578 default and1491202 maximum clocks.
The fixed maximum numerical cases both use min_size1, reducing the paper
maximum to878338 clocks per frame. All tool children still have an independent
20-second process-tree limit and must stop on the first failure/timeout.

LOW default / MEDIUM maximum is a qualitative architecture judgment. Five
bank granularity, shared multiplier mapping, address/control fanout and backend
lookups require real implementation evidence before any fit/timing claim.
