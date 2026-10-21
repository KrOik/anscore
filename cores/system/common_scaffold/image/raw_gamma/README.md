# RAW/grayscale piecewise gamma and tone LUT

`raw_gamma.sv` is an actual single-channel streaming 8/10/12-bit input to 8/10/12-bit output tone mapper. Gamma is supplied by the host as a table; RTL does not hard-code an exponent. Use three instances for independent RGB tone curves.

For M=2^BITS-1, K=2^INDEX_BITS, load K+1 nodes including the maximum endpoint. Nodes have coordinates j*M/K. For input p, j=min(K-1,floor(p*K/M)), r=p*K-j*M, output=(node[j]*(M-r)+node[j+1]*r+floor(M/2))/M. Arithmetic is unsigned, nearest rounded, with exact full-domain endpoints and support for arbitrary nonmonotonic tables. The denominator is odd so exact half ties cannot occur. INDEX_BITS is 1..8 and no greater than BITS. Dimensions are 1..4096 with at most 65536 pixels.

Three elastic registered stages perform synchronous dual-node BRAM lookup, weighted blend, and constant division. Sustained initiation interval is one clock when CE and sink ready remain high. CE freezes state; transfers require CE. Output tokens remain stable during backpressure. A configuration transaction starts at cfg_begin, accepts nodes in any order, then commits. A distinct-node bitmap prevents duplicates from pretending completeness. Both banks are synchronous TDP RAM; writes target the inactive bank. Commit waits for the current frame and its DONE acknowledgment, then publishes atomically; the running frame always uses its latched bank. Hold request valid until ready and acknowledge configuration/frame completion explicitly.

Configuration errors: 1 incomplete table, 2 bad index, 3 configuration abort. Frame errors: 1 invalid SOF/EOL/LAST, 2 no active table, 3 abort, 4 illegal state. Reset clears validity/control, not RAM, including with CE low. Abort must span an enabled clock; it flushes the pipeline. On malformed frame or abort, outputs already consumed belong to a partial frame and must be discarded by the consumer. No automatic recovery of a partial frame is promised.

Commands from repository root:

```
python -B cores/system/common_scaffold/image/raw_gamma/run_tests.py
python -B cores/system/common_scaffold/image/raw_gamma/test_protocol.py
python -B cores/system/common_scaffold/image/raw_gamma/test_numeric_limits.py
python -B cores/system/common_scaffold/image/raw_gamma/run_synthesis.py
```

Independent Fraction oracle: 20 complete numerical frames, 38912 pixels, all input codes for five profiles, gamma/inverse gamma/nonmonotonic/random nodes, random CE/backpressure, every marker and endpoint. Includes B8/O8/INDEX8 (257 nodes) and genuine consecutive-cycle II=1 assertions. Protocol regression: 15 healthy frames/480 pixels plus incomplete/duplicate/bad-index/aborted tables, concurrent table writing, pending atomic commits, three malformed markers and recovery, abort/reset at all three pipeline stages, CE-low reset, and unconfigured-start failure. Parameter regression rejects 10 illegal configurations and exhaustively checks segment-index shortcut for all legal input/index widths.

Standalone Yosys synth_gowin -noalu -nodsp: B12/O12 INDEX4 is 1492 LUT-class, 220 FF, 4 DPX9B, 0 DSP; default INDEX6 is 1592 LUT-class, 270 FF, 4 DPX9B, 0 DSP. This is synthesis evidence only; no timing, place/route, board, camera quality, or video throughput acceptance is claimed.

Mature software references are fetched by optional fetch_references.py and recorded with URL/SHA/excerpts in references.json: libcamera libipa Pwl interpolation and Raspberry Pi contrast/gamma controller. No third-party code is copied. Their arbitrary floating-point coordinates differ from this explicitly quantized uniform integer-domain curve. Reference downloads are temporary and are deleted after extraction. Tests generate their own vectors and have no network dependency.

