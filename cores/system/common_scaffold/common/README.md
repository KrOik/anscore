# Native memory protocol adapters

`cip_native_ce_adapter` connects a shared-CE native initiator (the DMA cores) to
an ordinary ready/valid memory endpoint. The source transfers only on
`clk_en && valid && ready`; the memory side transfers on every physical clock.
One request and its response are registered independently of CE. A response
that arrives while CE is paused is retained until the source consumes it.

`cip_native_byte_ram` is an ordinary ready/valid synchronous RAM endpoint with
byte addresses, aligned whole-word reads, byte write strobes and a bounded
word count. Misalignment and out-of-range requests return an error. It does
not reset or initialize RAM contents. Unwritten bytes must be initialized
before use. This differs from the word-addressed RAM primitives in `memory/`.

Both endpoints must share the same physical clock and coordinated reset.
These modules do not perform clock-domain crossing. Reset aborts in-flight
traffic; there is no timeout or rollback. Parameter widths must match.

Do not directly connect a CE-paused DMA to an ordinary memory responder;
an unbuffered response can otherwise disappear while the DMA is paused.

Development check: `integration/tb_cip_dma_ce_memory.sv` writes 11 bytes through
the actual DMA, CE adapter and RAM, then reads them through the second DMA.
The check covers a memory reply during CE=0, output/response backpressure,
tail byte enables and byte/length/tag preservation. It is included in
`python cores/system/common_scaffold/run_tests.py` when both `memory` and
`stream_bus` groups are selected. No synthesis or board test was run.

`cip_unsupported_stream` remains the explicit error endpoint used by the
legacy `signal_video` templates; it is not a functional image algorithm.
