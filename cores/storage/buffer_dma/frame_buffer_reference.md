# Autonomous BSRAM frame buffer reference

`rtl/frame_buffer_reference.v` is a synthesizable single-clock subsystem,
not a physical pin top. Default SLOT_WORDS=256 allocates four slots / 1024 words.
FIXED_PINGPONG=1 assigns alternating slots 0/1 to producer0, 2/3 to producer1;
zero selects the shared four-slot pool.

Each producer first handshakes w_valid/w_ready with destination, frame ID and
length (16 bits each). It then sends exactly length full 32-bit words, keep=15,
last asserted only on the final word. Metadata may change after its handshake.
Payload must obey valid/ready. Completion is separately held until accepted,
including invalid-length allocation errors. Another command from that producer
waits for completion consumption. See word_dma.md for malformed packet abort
and reset requirements; this reference does not drain trailing malformed data.

The manager publishes only after all memory write acknowledgements. Each reader
automatically accepts a descriptor and emits its payload with stable descriptor
metadata alongside every word. Output uses valid/ready/data/keep/last; descriptor
format is in frame_descriptor.md. Read completion releases the slot only after
the last output handshake. All modules share reset, which invalidates queued
and in-flight frames without clearing payload RAM. Read/write errors abort their
slot and increment aborted; invalid allocations increment invalid_requests.

`requests`, `completions`, `memory_stalls` expose four packed 32-bit arbiter
counters. They do not replace end-to-end frame latency, bandwidth or overflow
instrumentation. Additional packed outputs `stream_bytes`, `stream_frames`,
`stream_stalls`, `stream_crc32`, `last_frame_cycles`, `last_frame_crc32` cover
input0/input1/output0/output1 in ascending 32-bit slices. A passive monitor
counts accepted bytes and last beats, valid-without-ready cycles, cumulative
CRC32/ISO-HDLC and the last completed frame's CRC and transfer duration. CRC
processes low-byte-first enabled keep lanes, matching Python zlib. Frame duration
is inclusive first-to-last acceptance, including intervening gaps and stalls;
it excludes time before the first word and is not end-to-end slot latency.
All counters wrap at 32 bits and clear only on common reset. Stalls indicate
backpressure, not overflow. Invalid input beats consumed by DMA are still
visible to the passive input monitor; frame/error counters must be interpreted
with aborted/invalid_requests. Monitors do not repair malformed packet boundaries.
The same-clock runtime CSR now captures these outputs atomically; see csr_map.md.
There is no external-clock stream support or physical JTAG transport binding yet.

Run (after scripts/env.ps1):
`python cores/storage/buffer_dma/tools/test_frame_buffer.py`

Current simulation evidence: artifacts/buffer_dma_25k/frame_buffer_20261020T163230837440Z.
This additionally verifies all four hardware cumulative and final-frame CRCs
against Python zlib and bytes/frames against independent traffic expectations.
Monitor unit evidence: monitor_20261021T003254896, standard "123456789"
CRC CBF43926, masked bytes, empty keep, exact frame duration/stalls, and reset.
Both allocation modes: 64 frames / 544 words; 32 variable-length frames per
producer, two independently stalled consumers, producer gaps and completion
backpressure. Full word/metadata/boundary checks and Python golden pass; each
consumer reads 272 words, CRC32 E3AE5E67 / 653C99DC. Both runs finish in 1916
simulation cycles including directed invalid-length and early-last abort checks.
These are finite simulation results, not sustained board bandwidth evidence.

Pre-monitor GW5A synthesis: frame_buffer_synth_20261021T003049230; 1537 LUT1..4,
675 ALU, 1498 FF, 153 MUX2_LUT5, 34 RAM16SDP4, 2 SPX9, zero DSP. LUT count
excludes distributed RAM and carry cells. SPX9 is a synthesis-cell count, not a
physical BSRAM report. The wide internal ports produce 878 port bits, so this
module requires a narrow board wrapper before P&R; no Fmax or board claim.
These resource figures predate the added monitor outputs/CRC hardware and do
not characterize the current monitored subsystem. Updated synthesis is pending.

Slot telemetry outputs now include latency_last/min/max/sum (two consumer slices),
elapsed_cycles, allocation_stalls and peak_occupied; see frame_descriptor.md for
exact endpoints and rollover. Current integration evidence is
frame_buffer_20261020T163433254741Z, superseding the earlier monitor-only source
hashes. The monitor and per-word payload/CRC checks remain enabled.
