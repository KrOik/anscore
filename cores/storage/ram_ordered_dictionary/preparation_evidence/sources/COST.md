# Architecture cost and bounds

Source reasoning only. Resource risk LOW for default logical storage, MEDIUM for
mapping/control timing until measured; actual LUT/FF/BRAM/DSP/Fmax/power UNKNOWN.
No synthesis, PnR, STA or hardware execution has occurred.

A sorted RAM array trades O(N) writes on mutation for exact sparse key ordering
without a pointer graph or CAM. Exact hash tables cannot provide ordered traversal
without another ordered structure; a balanced tree has better large-N update
complexity but needs pointer metadata, rotations and more control/ports. The
selected capacity<=32 intentionally targets small serialized control tables.

Let C=CAPACITY, K=K_W,V=V_W,A=max(1,ceil(log2(C))),
Q=max(1,ceil(log2(C+1))),W=8*ceil((K+V)/8).
The data RAM is C*W bits. Defaults:32*64=2048 bits. Minimum profile has one8-bit
physical row for two logical key/value bits. Padding is not logical state.

Beyond RAM, explicit logical registers are: six Q-bit count/search/index/cursor
registers;5-bit controller;3-bit opcode; two K-bit bounds and one V-bit command
value; one W-bit row; A-bit read address;1-bit replacement flag; response fields
2+3+1+K+V+Q bits. The shared RAM adds W data-response bits and2 response-control
bits. At defaults this is352 explicit logical register bits, before synthesis
elimination or FSM recoding. This is a source bit inventory, not an FF/PPA result.
No extra deleted-row buffer is needed: DELETE reuses its dead input-value storage.

One K+1-bit subtract and zero detection serve all full-key tests. Count/address
comparisons and increments are additional small operators. There are no
multipliers, DSP requests, dynamic dividers, shifts by runtime data, pointer RAMs
or combinational capacity-wide key comparisons. Binary search and row movement
are serialized through one request/response port.

All pointers/counts are unsigned. count/lo/hi/index may equal C, so use Q bits.
mid=floor((lo+hi)/2) uses a Q+1-bit sum. Under lo<hi<=count<=C,mid<C.
Only indices<count are read. A non-full insert writes the old count, at most C-1;
full insertion rejects before any write. Shift reads/writes remain in0..C-1.
Delete moves next row down and commits count-1 only after the last response.
For C=1 the shift states are unreachable. Stale physical rows beyond count are
unreachable after deletion/CLEAR/reset. Zero/all-ones keys are ordinary data.

Service reasoning (unmeasured, always-ready case): each binary-search iteration
uses SEARCH/request/wait/compare, four controller edges. At most
ceil(log2(count+1)) iterations are needed. Final lower-bound dispatch costs
two edges plus an optional two-edge bound read before OUT. Every moved row
requires one RAM read and one write, four controller edges. PUT adds a final
two-edge write; DELETE adds a completion edge. Each RANGE continuation reads
and checks one next row; successive unstalled ROW handshakes are four edges
apart. A physical-end ROW can be followed by END on the next edge; upper-bound
termination may need one read of the first excluded row. CLEAR/BAD_OP/BAD_RANGE
can respond on the edge after command acceptance. The next command is accepted
no earlier than the edge after RESULT/END retirement.

Backpressure has no bound, so completion/occupancy time has no unconditional
upper bound. There is no advertised per-cycle command throughput. Binary-search
comparison and RAM handshake are separate states; the expected control path
includes the compare input mux and one subtract/zero test. Physical timing and
RAM inference depend on target/tool constraints, which are intentionally absent.
