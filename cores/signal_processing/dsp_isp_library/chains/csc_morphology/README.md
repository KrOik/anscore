# Representative bounded ISP chain

Production `isp/csc_stream.v` (four registered stages) → its most-significant
gray lane → complete `isp/morphology/morphology_stream.v`. The representative
configuration is 8×8 RGB input, 8/10 bits/channel, 64 grayscale output pixels,
3×3 morphology and ZERO/REPLICATE borders. It supports erosion, dilation,
opening and closing, grayscale/binary processing and programmable nonempty masks.
This is a complete two-algorithm chain, not separate self-tests or a reducer only.

`csc_morphology_stream` uses standard Stream data/valid/ready and SOF/EOL. RGB
packing is R in the most-significant lane, B in the least. CSC mode is fixed to
gray; BT.601/709 and Full/Limited are configurable. The configured grayscale
output is quantized by the unchanged production CSC before morphology; the
independent model intentionally includes that quantization boundary.

One 32-bit config word transfers atomically:

| Bits | Meaning |
|---|---|
| 0 | 0 BT.601 / 1 BT.709 |
| 1 | 0 Full / 1 Limited |
| 3:2 | 0 erode / 1 dilate / 2 open / 3 close |
| 4 | binary normalization (nonzero gray → 1) |
| 13:5 | nonempty row-major 3×3 mask |
| 31:14 | reserved zero |

Config ready requires no frame in flight and no accepted configuration awaiting
its first SOF. A registered pending flag avoids a feedback path through CSC's
combinational commit-ready. Both child configs transfer on the same clock. First legal configuration is mandatory after
reset; before it the source is backpressured. A new frame cannot enter until the
previous final output transfers. A queued next config does not interrupt the
active frame, and config wins over new input at the next boundary. Invalid masks
or reserved bits pulse cfg_error. Config_done acknowledges accepted legal words.

Synchronous reset discards all in-flight state without clearing window RAM.
Markers are generated/checked per row (EOL every eight pixels for the board
configuration), never as a single 64-pixel row. Backpressure propagates through
both algorithms; held output is stable. CSC is II=1, but the row-cache morphology
stages determine frame throughput. No continuous RGB pixel-rate guarantee is made.

Run `python cores/signal_processing/dsp_isp_library/chains/csc_morphology/test_chain.py`.
Evidence `evidence/20260925_034523_521349/` has all four 8/10-bit × border cases
PASS: 192 full 8×8 frames across three reset epochs, queued frame configs, random
source gaps, long/random output stalls, held-output reset, exact first-output
latency and row-II checks, malformed-marker diagnosis and sixteen verifier
mutation rejections. Numerical reference composes unchanged independent CSC and
morphology models, comparing every pixel and both markers.

The separate `board/image_harness` provides external UART loading, target-clock
RAM replay and full result export. Physical acceptance is exclusively the main
agent's task. Standalone simulation is not evidence that the shared inferred
window memories have passed the current silicon investigation.
