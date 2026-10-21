# Infrastructure reuse and memory boundary audit

This is a bounded source/evidence inventory, not physical qualification.

| Goal item | Existing capability | Remaining work |
|---|---|---|
| INFRA-01 | New elastic and synchronous FIFO, tested metadata and reset | Shared atomic configuration/status/error-counter packaging and physical integration |
| INFRA-02 | New K=3/5 VALID plus ZERO/REPLICATE row cache | P&R, data-driven board windows and chain qualification |
| INFRA-03 | comm_20k fifo_async Gray pointers, two-stage synchronizers, registered read; CNN my_fifo; legacy adapters | True independent clocks, coordinated reset contract, Stream adapter, CDC constraints/review and fresh board evidence |
| INFRA-04 | New DC/CSC/statistics models; external random UART probe; block load/replay/capture | Coefficient/LUT generation across remaining algorithms, full qualification and throughput reporting |
| INFRA-05 | CORDIC legacy, per-core new quantizers, statistics integer square root | Reusable signed saturation/rounding, complex MAC, reciprocal/division, sqrt/log/exp contracts and independent precision tests |
| INFRA-06 | wave2 dma_sg between on-chip RAMs; official 20K DDR example | Stream backpressure, atomic descriptor/range validation, ping-pong/watermark/overflow, external DDR qualification |
| INFRA-07 | wave2 PRBS/LFSR/CRC and new host random vectors | Shared image/multitone/chirp/sequence/trigger sources and corruption-sensitive per-result sinks |

`comm_20k/ip/fifo_async/README.md` reports an old clk-to-clk/2 selftest. That is
not arbitrary independent-clock, single-sided-reset or metastability evidence.
Its raw wr_en/full and rd_en/empty ports are not a complete Stream contract.
The derived-clock digest is retained; no new CDC acceptance is inferred.

`wave2_ip_20k/src/dma_sg.v` is a descriptor-controlled on-chip RAM mover, not a
DDR/AXI burst engine. It has legacy asynchronous reset and clk_en. Address
addition truncates to AW; therefore new use must range-check descriptors and
define overlap/wrap behavior. Its implementation ideas may be reused without
renaming it an external-memory controller.

## DDR discovery

Source filename searches found official Tang Primer 20K DDR test/camera examples
under `official/TangPrimer-20K-example/`, including
`DDR-test/LicheeTang20K_DDR_Test/src/ddr3.cst` for **GW2A-LV18PG256C8/I7**.
The corresponding `ddr3_memory_interface.v` begins with Gowin encrypted IP
(`pragma protect`, GowinSynthesis 1.9.8.05). Its presence is not an OSS build or
board acceptance result. No working DDR controller was found in the searched
`projects/**/*ddr*.v/.sv/.cst` set. Other DDR files under external/CNN_FPGA are
project/vendor-specific and have not been ported or verified for this board.

External-memory-dependent resolutions remain a separate unqualified dependency.
The goal explicitly allows bounded on-chip reference images. Initial full-frame
algorithm planning uses 32x24 or 64x48, never an arbitrary-resolution claim.

Planning only: 32x24x30 color bits = 23040 useful bits; padded to two 18-bit
banks it fits two 18-Kbit BRAMs. A 64x48 color frame uses six such BRAMs;
double buffering uses twelve, before labels, windows or algorithm state.
The 46-BRAM device ceiling is 847872 raw bits, not fully usable payload after
port-width, banking and depth fragmentation. Each actual configuration still
needs mapped counts, access bandwidth and resource/timing gates. Serial loading
and 27MHz buffered replay are distinct rates.
