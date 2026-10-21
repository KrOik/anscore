# IP-02 BSRAM transaction foundation, version 0.1

Status: memory port, arbitration, slot ownership and autonomous frame DMA
reference implemented and simulation-tested; physical acceptance is incomplete.
Default platform target is GW5A-25. No board-level qualification yet.

`mem_port_bram` is a single-clock, 32-bit, byte-addressed transaction backend.
Requests carry valid/write/address/data/strobe. Each valid/ready handshake
produces exactly one response, including writes and invalid accesses.
Responses carry valid/data/error and remain stable while ready is low.
Writes return zero. Reads return a synchronous RAM word; read strobes are
ignored. Byte write strobes select lanes 0..3. A zero-strobe write succeeds
without changing RAM and counts as one write.

Addresses must be four-byte aligned and less than DEPTH*4. Invalid requests
return error/zero with no RAM access, so high address bits never alias low
addresses. DEPTH is a power of two from 2 to 1048576 words, default 256.
Large logical parameter values are not guaranteed to fit 25K; check actual PPA.
RAM contents are undefined before writes and survive control reset.

Reset asynchronously aborts response/control state. It does not undo a write
accepted before reset. Data must be initialized by the owning controller.
The RAM array has no reset and no asynchronous read. Reset release must meet
the enclosing clock-domain timing contract; this component supplies no CDC.
Reads/writes/errors count accepted valid reads/writes/invalid transactions,
respectively, modulo 2^32. Counters clear on reset.

`mem_port_arbiter4` multiplexes four independent masters into this interface.
Packed ports use channel0 in the least-significant slice. Masters are symmetric;
the reference scenario uses masters0/1 as writers and masters2/3 as readers.
Each master has one reserved response slot from request acceptance until its
response is consumed. A blocked consumer therefore does not block other masters.
Round-robin selection advances on backend request acceptance. Selection and
request fields are held while the backend stalls. Upstream must keep requests
stable until accepted. Backend must return exactly one ordered response per
accepted request and hold it until ready.

There is one backend request in flight; its response and the next request may
handshake on the same edge. With eligible masters and an unstalled backend,
peak issue rate is one transaction/cycle. This is not a measured steady-state
throughput or frame-DMA guarantee. Continuously eligible masters wait at most
three other accepted grants, excluding their own reserved response and backend
stalls. Arbitration does not resolve application-level read/write data hazards.

Per-channel metrics: requests count forwarded request handshakes; completions
count responses placed into the channel's response slot, not final consumption;
stalls count cycles with input valid and ready low. All wrap at 2^32 and reset.
Metrics are same-clock independent counters, not an atomic snapshot interface.

Frame descriptors/rings and synthesizable four-slot ownership/ping-pong control
now exist; see frame_descriptor.md for the separate verification and contracts.
`frame_buffer_reference` connects two full-word producer streams and two
consumer streams through four autonomous word DMA engines, the slot manager,
four-master arbiter and synchronous BSRAM sized to 4*SLOT_WORDS. See
frame_buffer_reference.md. Still required for full IP-02: CRC/latency/
overflow instrumentation, CSR/control integration, target P&R and physical
two-writer/two-consumer acceptance. SDRAM remains optional and is not implemented.
