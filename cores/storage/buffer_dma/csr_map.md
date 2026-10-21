# Coherent telemetry CSR v1

Same-clock transport-neutral request/response interface follows the IP test
shell's byte-addressed 8-bit CSR contract. Hold request until ready; response
data/error/valid hold until accepted. One response slot supports consume plus
next request on the same edge. No CDC or physical JTAG binding is supplied here.

| Byte address | Access | Meaning |
|---|---|---|
| 0x00 | R/W | Read snapshot ID; full-strobe write of exactly 1 captures all metrics |
| 0x04 | R | Snapshot timestamp low 32 bits |
| 0x08 | R | Snapshot timestamp high 32 bits |
| 0x0C | R | Bit0: snapshot has been captured since reset |
| 0x10..0xD8 | R | 51 snapshot words, word index=(address-16)/4 |

Capture returns data=0/error=0. Capture and its acknowledgement occur at the
same edge; the next accepted read observes the new bank. Timestamp and metrics
sample pre-edge state. Reads do not consume the snapshot; it remains immutable
until the next accepted capture or reset. ID increments modulo 2^32. Timestamp
counts clocks since reset (64-bit wrap). Capture-valid is independent of ID wrap.
Read metadata is allowed before capture, but metric reads return error/zero.
Reset aborts a pending response and clears snapshot, ID, timestamp and validity.

Misaligned/unmapped addresses, writes to read-only words, partial-strobe writes,
and capture values other than 1 return error/zero with no capture or other side
effect. Read strobes are ignored. The CSR cannot reset traffic or counters.

| Metric word(s) | Meaning |
|---|---|
| 0,1,2,3 | published, released, aborted, invalid_requests |
| 4..7 | memory requests, masters 0..3 |
| 8..11 | memory completions, masters 0..3 |
| 12..15 | memory input stall cycles, masters 0..3 |
| 16..19 | stream accepted bytes |
| 20..23 | stream accepted last beats |
| 24..27 | stream valid-without-ready cycles |
| 28..31 | cumulative stream CRC32 |
| 32..35 | last frame transfer duration |
| 36..39 | last frame CRC32 |
| 40..41 | successful slot latency last, consumers 0..1 |
| 42..43 | slot latency minimum |
| 44..45 | slot latency maximum |
| 46..47 | slot latency sum |
| 48 | elapsed cycles |
| 49 | allocation wait cycles, summed across producers |
| 50 | peak occupied slots, low 3 bits |

Stream order is input0,input1,output0,output1. Counter/CRC/latency definitions
are in frame_buffer_reference.md and frame_descriptor.md. Snapshotting is
coherent within one clock domain; multi-register CSR reads are coherent only
if no other control master captures another snapshot in between. Use one owner
or verify the ID before/after reading. No software lock is implied.

Verification: test_frame_buffer.py checks integrated CSR publication/error/peak
values and response backpressure, plus complete DMA payload and hardware CRCs.
Evidence frame_buffer_20261020T163653168562Z.
Independent tb_csr_metrics_snapshot parameter cases 1/51/60 each verify two
generations against changing live values, all snapshot words, reset, malformed
accesses and stalled responses; evidence csr_snapshot_20261021T003720599.
The canonical sys_register_snapshot.v remains unchanged and is a required source.
Current synthesis must be rerun with the CSR bank; prior resource reports exclude
the snapshot storage and read mux. No new physical-board evidence this step.

The integrated control wrapper reserves E0..FC for selftest controls and status; see BOARD_CONTROL.md. Addresses DC..DF remain unmapped.
