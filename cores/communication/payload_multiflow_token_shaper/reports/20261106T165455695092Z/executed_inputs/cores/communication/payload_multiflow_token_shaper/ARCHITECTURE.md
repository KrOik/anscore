# Architecture and resource decisions

The existing clock-quantized descriptor shaper is reused unchanged. It supplies
per-flow token state, whole-cost eligibility and round-robin bypass. Its normal
descriptor retirement is deliberately connected only to actual public SOP
transfer. One wrapper flow-state machine adds FREE/COLLECT/COMPLETE/QUEUED/ACTIVE
payload ownership. The ACTIVE slot outlives descriptor retirement until public
LAST, preventing reuse or reconfiguration during packet output.

Each flow owns one `cip_sync_sp_ram` bank of MAX_BEATS packed DATA+KEEP words,
rounded up to a byte multiple for the canonical byte-write interface. Every
word is fully written, including masked DATA bytes and zero KEEP. The shared
collector and selected transmitter can access independent banks in the same
clock. The same flow cannot be both COLLECT and ACTIVE, so each bank needs one
port. A shared dual-port bank would require extra ownership/address arbitration
and is outside the selected supported dependency domain.

The final accepted ingress beat computes exact byte cost and complete-beat
count, then publishes COMPLETE metadata. A serialized descriptor admission
changes COMPLETE to QUEUED. When the descriptor engine selects an eligible
packet, the wrapper captures a trusted owner, cost, beats and tag and marks
ACTIVE. A one-response RAM slot feeds the unchanged depth-two synchronous FIFO.
This buffer absorbs downstream stalls and supports one payload beat per clock
within an always-ready body. Prefetch never spends credit. sh_m_ready equals
the public SOP handshake even after a diagnostic fault; a held valid first beat
cannot become an uncharged public transfer.

For accepted LAST at edge E with no older packet, eligible initial credits,
free descriptor engine and ready sink, descriptor acceptance is E+1, selection
E+2, owner capture E+3, first RAM read E+4, FIFO capture E+5, and public SOP E+6.
This is a source-derived first-transfer schedule, not a hardware measurement.
Packet boundaries have ownership/prefetch bubbles; no line-rate claim is made.
Unbounded source gaps, missing LAST, insufficient rate-zero tokens or output
backpressure have no completion deadline. A complete credit-poor flow does not
block another eligible flow, but an already selected packet is nonpreemptive.

Considered alternatives were direct descriptor-only composition, the existing
shared packet queues, separate payload banks, and copying an external AXI rate
limiter. Descriptor-only composition does not own or validate payload. Existing
shared_packet_queues serializes explicit commands/POP and has no automatically
published packet head or concurrent collection/transmit contract. Per-flow
canonical single-port banks satisfy the bounded one-packet/flow requirement
with simple ownership. External accumulator rate limiting cannot supply the
chosen exact-byte, complete-packet admission semantics.

Default RAM payload is 4*512*40=81,920 bits (10 KiB); maximum is 8*512*72=294,912
bits (36 KiB). This excludes the small depth-two FIFO, RAM response registers,
packet metadata and existing token/configuration registers. Memory contents are
not reset. There is no multiplier, divider or DSP requirement in the new
wrapper; byte charging uses at most eight KEEP bits. Selection and wide muxes
scale with at most eight banks. Default structural risk is MEDIUM and maximum
risk HIGH because of RAM packing, bank fragmentation and output mux routing.
There are no measured area, clock, power, vendor primitive or board results.
