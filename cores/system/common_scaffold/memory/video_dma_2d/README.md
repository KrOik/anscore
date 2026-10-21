# 2D AXI4 video DMA

`video_dma_2d_axi32.v` implements a 32-bit AXI4 master, with run-time memory-to-stream (`cfg_write=0`) and stream-to-memory (`cfg_write=1`) directions. This fills a separate role from the existing linear native-port DMA and AXI slave/native bridge; neither old module is copied or changed.

On `start_valid && start_ready`, snapshot base, row byte count, byte stride and 16-bit row count. Base/stride must be four-byte aligned, row bytes/rows nonzero, stride >= row bytes, final addressed byte within the 32-bit address space, total bytes <= 0xffffffff. Invalid commands, including invalid static `MAX_BURST` outside 1..256, return error 2 without bus access. Stride is the distance between row starts; holes remain untouched. Tail byte count may be arbitrary: low stream lanes are used and `keep` must be contiguous low ones. Reads issue a final full-width AXI word and mask unused lanes in `m_keep`; the containing word must be readable. Write unused lanes have WSTRB=0.

Bursts are aligned 32-bit INCR, at most MAX_BURST beats (default 16), bounded by the row and next 4KB boundary. Exactly one AXI transaction is outstanding. No IDs are needed (tie system ID to zero where required); no unaligned, narrow, WRAP, FIXED, overlapping rows or multiple outstanding operation is claimed. AXI optional cache/protection/QoS/region signals can be tied to system-appropriate constants.

Stream `s_eol/m_eol` marks each last row word; `s_last/m_last` marks the final frame word. Write source must exactly match computed keep/EOL/last; mismatch gives error 3. Read unused data lanes are unspecified, masked by keep. Output data and all valid payloads remain stable while stalled. New stream input and start acceptance require `ce`. **AXI handshakes, exposed read-stream output handshakes, abort, completion acknowledgement and reset remain active on every clock independent of ce.** The user must count every `m_valid && m_ready`, even ce=0. ce is an issue throttle, not a global freeze.

Abort is sticky, error 5. Already exposed address VALID is never withdrawn. Committed read bursts are drained without publishing further words. Committed write bursts retain a previously exposed buffered word (its WDATA/WSTRB cannot be changed while stalled), then send zero-WSTRB padding through WLAST and drain B. Pending exposed output must be consumed before DONE; a consumer holding READY low can intentionally delay completion. Partial writes are not rolled back. Bus response errors give code 4 and drain the current transaction. RLAST mismatch also gives code 4, but a peer violating beat count and then stopping can require external reset; no timeout can safely repair a nonresponsive AXI peer. Errors require discarding the partial frame.

`done_valid` holds until `done_ready`; error 0 means success. `bytes_done` is progress, not a transactional commit count: read counts bytes of successfully accepted R words published to the stream buffer (including an exposed word not yet consumed); write counts input-backed W transfers sent before sticky kill, without waiting for B. Already killed padding is excluded. An abort asserted on the same edge as a previously exposed W transfer may still count that transfer. On successful completion the value is exactly rows*row_bytes. Failed frames must not use it to infer committed storage.

Run from repository root:

```
python -B cores/system/common_scaffold/memory/video_dma_2d/run_tests.py
python -B cores/system/common_scaffold/memory/video_dma_2d/synth.py
```

Actual RTL simulation uses a backpressured AXI byte RAM, with independent Python byte-array oracle, write/readback, stride-hole checks, partial tails, start configuration mutation, held VALID assertions, CE-off output consumption, completion hold, read/write abort, BRESP/RRESP errors and subsequent recovery. MAX_BURST 1/16/256 each run 33 commands, including 2185 healthy read beats; 0/257 are rejected separately. Test profiles include base 4092 and 8188 with 4097-byte rows so 4KB and maximum burst boundaries are exercised. KEEP, EOL and LAST errors are injected independently. RLAST tests inject an incorrect first-beat flag or suppress the final-beat flag, with RRESP=OKAY and exactly the promised beat count still supplied. Each new EOL/LAST/RLAST error is followed immediately by its own healthy read recovery. This proves marker-error detection and recovery with a responsive peer; it does not claim repair of a peer that terminates early or stops responding. Malformed marker/keep and geometry/extent errors are explicit; this is functional simulation, not routed timing or board validation.

Gowin `synth_gowin -nodsp; check -assert` reports default 3823 LUT-class, 0 DSP, 0 BRAM9; MAX_BURST=256 is 3821/0/0. LUT-class includes LUT+ALU+MUX+4*RAM16SDP4, BRAM9 uses two per block RAM primitive. No pin/routed timing or board qualification is claimed. All compile outputs and full RAM dumps live in TemporaryDirectory and are removed. Small source-bound results and synthesis logs are retained.

External design references and retrieved hashes/excerpts are in references.json; original narrow RTL is not an upstream code copy. ARM specification landing retrieval failed certificate validation; that entry is explicitly unavailable. Both mature verilog-axi DMA source references were actually retrieved through the local network proxy.

