# Pixel-marker / AXI4-Stream Video bridges

Two real elastic streaming adapters, each supporting one accepted pixel per
clock continuously at CE=1 without downstream backpressure. Each START handles
one frame; DONE acknowledgment allows the next frame without reset. There is
no forced reset, resynchronization or silent marker correction.

`video_stream_to_axis` converts `s_pixel,s_valid/s_ready,s_sof/s_eol/s_last`
to `m_axis_tdata,tvalid/tready,tuser,tlast`. AXI `TUSER` is frame SOF and `TLAST`
is EOL, never end of frame. `axis_to_video_stream` performs the reverse and
derives image LAST from configured geometry.

Both modules have `clk,rst_n,ce,start_valid/start_ready,cfg_width[15:0],
cfg_height[15:0],abort,done_valid/done_ready,frame_error,error_code[7:0]`.
Parameters `WIDTH=16,HEIGHT=12` are maximum configured dimensions, legal 1..4096;
runtime dimensions must be nonzero and no greater than these limits.
`DATA_WIDTH=24` is legal 1..64. Data is opaque and preserved bit-exactly.
Configuration snapshots on START. No color conversion or clock-domain crossing.

## Transfer and termination contract

AXI transfers happen on **every** rising clock with VALID&&READY, including
CE=0. AXI VALID is never gated by CE. The TX register retires during CE=0;
the RX input buffer captures during CE=0 and deasserts READY when full. Internal
pixel and START/DONE handshakes require CE&&VALID&&READY. Pixel output remains
stable under either CE disable or backpressure. Synchronous active-low reset
overrides CE and flushes the complete interface state, as with an AXI reset.

TX permits simultaneous output retirement and input refill. RX has independent
input and output registers and permits simultaneous capture, advance and
retirement. It suppresses refill when processing the final configured pixel,
preventing acceptance beyond the current frame. These are single-clock bridges.

SOF must be true only on the first pixel and EOL only at each configured row
end. The internal pixel LAST must identify exactly the final configured pixel.
Errors: 1 invalid static/runtime geometry/data width, 2 malformed markers,
3 requested abort. Errors never silently restart or search for a later SOF.
After errors discard the entire partial frame. On abort, an already exposed
output remains valid and unchanged until its legitimate handshake. TX drains
AXI regardless of CE; RX drains exposed pixel only with CE. Buffered RX input
not yet exposed may be discarded, including an AXI beat accepted concurrently
with abort. After abort capture, no more input is accepted. DONE appears after
the exposed output drains and is held until CE-qualified acknowledgment.
Abort in IDLE or DONE is ignored; repeated abort can delay terminal progress
until abort is lowered. Consumer must continue servicing exposed output even
after requesting abort. Reset is the exception that explicitly flushes VALID.

## Verification

```
python -B cores/system/common_scaffold/image/axi_video_bridge/test_to_axis.py
python -B cores/system/common_scaffold/image/axi_video_bridge/test_from_axis.py
python -B cores/system/common_scaffold/image/axi_video_bridge/run_tests.py
python -B cores/system/common_scaffold/image/axi_video_bridge/test_protocol.py
python -B cores/system/common_scaffold/image/axi_video_bridge/test_parameters.py
python -B cores/system/common_scaffold/image/axi_video_bridge/test_throughput.py
python -B cores/system/common_scaffold/image/axi_video_bridge/synth.py
```

Narrow independent per-module cases check exact data/markers on 12 pixels each.
The chained regression checks both the intermediate AXI stream and returned
pixel stream against independent Python-generated values. Five profiles cover
1x1 DW1, 7x5 DW8, 16x12 DW24, 64x32 DW32, 4096x1 DW64: 20 frames, 25,488 pixels,
25 deliberately observed CE-off AXI handshakes, random CE/backpressure, held
VALID/data/markers, configuration capture and repeated frame completion.
Protocol regression covers 28 healthy recovery frames, 22 marker/dimension/
abort errors plus CE-off input capture, output drain, reset and held DONE.
Twelve invalid static profiles cover each parameter bound in each direction.
Dense test strictly asserts consecutive output transfers every clock on both
AXI and pixel sides: 128x8 x4 frames, 4096 pixels, initiation interval one.

`synth_gowin -nodsp; check -assert` isolated resource profiles:

| Module | 16x12 DW24 | 4096x4096 DW64 | DSP | BRAM9 |
| --- | ---: | ---: | ---: | ---: |
| video_stream_to_axis | 226 LUT-class | 192 LUT-class | 0 | 0 |
| axis_to_video_stream | 221 LUT-class | 199 LUT-class | 0 | 0 |

LUT-class includes LUT, ALU, MUX and four per RAM16SDP4. Every block RAM
primitive counts as two conservative BRAM9 units. Source-bound reports include
all actual cells and log SHA256. No routed timing, independent AXI clock domain
or board-validation claim. All simulation products use TemporaryDirectory.

`references.json` records actually fetched official Xilinx Vitis vision adapter
guide and mature verilog-axis elastic-register code, URLs, content hashes and
excerpts. The RTL here is an original implementation.
