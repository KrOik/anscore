# Declared storage and conservative schedule

Let N=NUM_NODES, T=TAG_W, I=max(1,clog2 N), C=clog2(N+1),
E=clog2(N*N+1). No physical implementation has been performed.

Local RAM: adjacency N*N, captured closure N*N, reduced rows N*(N+C).
Total local=3N*N+N*C bits. Existing backend declares
N*N+N*(N+I+3C) bits. Combined=5N*N+N*I+4N*C:
1664 atN16/T8;22656 atN64/T32. All five banks have synchronous read OR write,
and neither payload nor read-data resets. Both initialization sweeps write one
row per clock. Captured closure and reduced output each have complete write
ownership before any read. Small wide banks may fragment or map to registers.

Local sequential declarations:

|Storage|Bits|
|---|---:|
|state|4|
|adjacency_q,reach_q,direct_row,redundant,reduced_mask|5N|
|reduced_q|N+C|
|init_row,pending_from,pending_to,compute_row,successor,count_bit,output_node|7I|
|pending_present,pending_last,first|3|
|tag,frame_error,degree,original_edges,reduced_edges|T+2+C+2E|
|all public output registers|4+T+I+N+C+2E|

Sum=7N+8I+3C+4E+2T+13,224 default /746 maximum. The combinational update_row
is not storage. Backend source declares16+8N+12I+11C+2T bits,263 /741;
combined487 /1487. Unconnected backend outputs may optimize away, but that is
not subtracted from the source budget or described as a synthesis result.

Final edge state A and captured R are N-bit rows. The union excludes exactly
the current successor's reflexive bit. OR never creates a bit outside N.
For every legal DAG, original E_G<=N(N-1)/2; the E-bit unsigned total counters
can represent N*N, including all intermediate prefixes, so there is no count
wrap before narrowing. Degree C represents0..N. Full32 endpoints compare to N
before any I-bit address conversion. No variable multiplier/divider exists.

After accepted tail, the backend's documented first-valid bound is
4N*N+6N+8 including pending input RMW. All N backend rows retire within a
further3N-2 clocks with wrapper ready in COLLECT. Local row work costs
2N+4+2*out_degree_original clocks; summing over a DAG gives at most
3N*N+3N. OUT_READ and OUT_LOAD add2. Total<=7N*N+12N+8:
1992 default /29448 maximum. Atomic errors finish sooner. Normal later rows
retire every3 clocks with ready1. After final retirement, N initialization
clocks precede the next ready edge; earliest new acceptance is N+1 clocks.
External source gaps and sink stalls are unbounded and excluded from service
claims. The risk is LOW default /MEDIUM maximum, not an Fmax or power estimate.
