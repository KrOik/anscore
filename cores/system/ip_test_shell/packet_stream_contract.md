# Packet stream contract v1

One transfer occurs at a rising clock edge when valid and ready are both high.
The source holds valid, data, keep, last and user unchanged while stalled.
Reset is active low and aborts partial packets; consumers must discard the
aborted transaction. This single-clock contract does not itself provide CDC.

Data widths are 8, 16, 24 or 32. Each keep bit qualifies its byte lane; lane 0
is the first byte on the wire. Sparse keep is compacted in increasing lane order.
Last ends the packet independently of keep. A keep=0,last=1 transfer preserves
an empty boundary. If an exactly full output word precedes an empty terminal
input, the output contains a separate keep=0,last=1 boundary beat.

User is 8-bit packet-constant metadata. Producers must keep it constant within
a packet, including zero-byte transfers. Consumers ignore data lanes whose
keep is zero. For the adapter, unused output lanes are zeroed.

`stream_width_adapter` reuses canonical `sys_width_converter` MODE=0, then
packs one byte per cycle into the requested output width. This is a functional
width adaptation path, not a parallel full-word-rate converter: peak internal
rate is one byte/cycle, and backpressure/boundary bubbles reduce achieved rate.
No drops or packet merging are permitted. No timeout or malformed-user detector
is supplied in this module; source contract checks belong to the test shell.

Video SOF/EOL use the explicit adapter and video_stream_contract.md: one line
per packet, last=EOL, packet-constant first-line metadata, and reconstructed
SOF on the first pixel. Full frame scheduling and physical video acceptance
remain pending.
