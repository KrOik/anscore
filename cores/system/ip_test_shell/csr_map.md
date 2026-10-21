# Test shell CSR map v1

Endpoint is synchronous to clk, with independent valid/ready request and
response channels and one response slot. Requests carry write, byte address,
32-bit data and four little-endian byte strobes. Every accepted request has one
response (writes return zero); invalid accesses return error and no side effect.
Response data/error stay stable while stalled. The standalone endpoint permits
consume/replacement on the same edge; the integrated core serializes requests
with one response-routing slot. Reset aborts pending requests and clears start.

| Byte address | Access | Meaning / reset |
|---|---|---|
| 0x00 | R | ID 0x49503034 |
| 0x04 | R/W | Read bits 0 busy,1 done,2 run_error; write bit0=1 pulses start for one clock if idle |
| 0x08 | R/W | probe_page 0..7; reset 0; may update while busy |
| 0x0c | R/W | stimulus seed; reset 1 |
| 0x10 | R/W | length 1..256; reset 16 |
| 0x14 | R/W | downstream stall mask; reset 0 |
| 0x18 | R | frame counter snapshot |
| 0x1c | R | dropped-packet counter snapshot |
| 0x20 | R | run-cycle counter snapshot |
| 0x24 | R/W | Trace word index 0..511; full-word writes while idle only |
| 0x28 | R | Selected trace bits 31:0; idle and index<trace_count required |
| 0x2c | R | Selected trace bits 35:32 in low nibble; same guards |
| 0x30 | R | Trace word count |
| 0x34 | R | CRC32/IEEE of accepted payload bytes |
| 0x38 | R | Accepted payload byte count |
| 0x3c | R | Core interface version 0x00010000 |

Seed, length and stall mask writes while busy fail without modification.
Byte strobes merge configuration values before range validation. Invalid page,
length, unaligned/unmapped addresses and writes to read-only locations fail.
Start requires strobe[0] and data[0]. It is a command pulse, not stored state;
the owning runner must assert busy when accepting start. No autonomous run is
performed by this endpoint. Counters/status must be in the same clock domain;
each read snapshots one register, not a multi-register atomic snapshot.

`axil_csr_bridge` provides a 32-bit AXI-Lite slave with 8-bit byte addresses.
AW, W and AR are buffered independently. AW/W may arrive in either order.
Read/write dispatch alternates priority, with one active backend request.
Requests stay stable until accepted; B/R responses stay stable until consumed.
CSR errors map to SLVERR (2), successful accesses to OKAY (0).

The enclosing decoder must validate high address bits before selecting this
256-byte aperture; truncating a larger address would alias registers.
Protection attributes are not interpreted; any privilege policy belongs in
the enclosing design. Both modules share clk/rst_n.

Runtime hard JTAG transport and board acceptance remain open; a simulated write is not a
claim of physical JTAG command delivery.

Registers 0x24..0x3c are supplied by `ip_test_shell_core`, not the standalone
CSR endpoint. Trace words are `{last,user[7:0],keep[2:0],data[23:0]}`. Memory
read is synchronous; the core's request/response sequencing gives index writes
time to complete before data access. Unwritten/out-of-range reads fail.
Version is an interface number, not a bitstream/source fingerprint.

The current runner emits one packet from each of four sources, in source order
0..3. Length is payload bytes per source (1..256). Byte i of source s is
`(seed + 73*s + i) mod 256`. This controlled generator is separate from a
separate host-loadable stimulus RAM. Stall mask bit cycles[4:0] suppresses sink
ready. A run resets the internal DUT pipeline and counters, not FPGA configuration.
Maximum accepted trace is 344 words, within the 512x36 response memory.
The 128-word packet FIFO can hold any valid generated packet. Its drop CSR
is therefore zero for legal traffic; unexpected drops terminate the runner as
an error. An all-one stall mask causes an explicit timeout.

## Host-loaded path (additive aperture)

0x40..0x64 decode a separate csr_capture_replay endpoint; subtract 0x40 to
obtain offsets in CAPTURE_REPLAY.md. 0x4c selects a stimulus index; 0x50 writes
its word; 0x54 selects a response index; 0x58 reads it. 0x44/0x48 select
input/output counts; 0x40 launches/reads status; 0x5c reads elapsed cycles;
0x60/0x64 return issued/captured word counts. These are independent of the
generated runner. Each word is one four-byte packet through source 0 of the
fabric and repacker. Full-word writes only; active mutations and invalid
response reads fail. Response selection is held until consumed, independent
of later req_addr. 0x68 and higher remain unmapped. Page 2 at 0x08 selects
registered loaded-path probes. Physical hard-JTAG acceptance remains open.
