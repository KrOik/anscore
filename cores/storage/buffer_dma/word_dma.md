# Acknowledged frame word DMA

`rtl/frame_word_dma.v` implements one autonomous descriptor transfer. WRITE=1
consumes a full-word packet and writes memory; WRITE=0 reads memory and emits
a full-word packet. start_valid/start_ready samples byte base and word count.
The caller owns the slot and descriptor metadata. Only one command is active.

Every word waits for its memory response. Write completion follows the last
successful write acknowledgement; read completion follows acceptance of the
last output word. Output and request fields remain stable under backpressure.
done_valid/error remains asserted until done_ready. Counters report successful
words, active cycles and wait cycles for the most recent command (32-bit wrap).

Zero length, misalignment, address wrap, memory errors, partial keep and
incorrect last cause an error completion. A malformed input word is consumed
but never written. Earlier writes are not rolled back. On input errors the
upstream packet must be aborted/flushed before submitting another descriptor;
this module does not silently drain an unknown packet length. Reset aborts
control only; the slot manager and peer streams must reset consistently.

This conservative engine holds at most one word and one memory request, and
does not claim burst or one-word-per-cycle throughput. No CDC is supplied.
Slot-manager integration, full-system bandwidth/latency/overflow monitoring,
target P&R and physical 25K acceptance remain open.

Verification: after sourcing scripts/env.ps1, run
`python cores/storage/buffer_dma/tools/test_word_dma.py`.
Both directions check lengths 1/2/4/8/16/32/64 against BRAM, deterministic
request/output stalls, completion stalls, invalid commands, backend bounds
errors, and write keep/last errors. No synthesis performed for this module yet.
