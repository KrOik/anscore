# cnn_infer_138k — INT8 CNN inference IP for Tang Mega 138K Pro SOM

Target: GW5AST-LV138FPG676A (GW5AST-138C), 50 MHz SOM clock (P16).
Host link: NanoDAP debug-JST UART, 115200 8N1 (COM25). TX=P15 (verified);
RX=N16 (verified via wide-pin probe).

Goal: board-verifiable CNN/NN compute IP. No training; weights are fixed,
generated deterministically by `host/cnn138k/gen_mems.py`. Functional
correctness first; engine sized to use a meaningful share of DSP/BSRAM.

## Network (all parameters fixed at build time)

```
img  28x28x1  uint8 (UART-loaded or $readmemh init)
conv1 3x3 s1 p1, 1->16 ch   -> 28x28x16  acc32 + bias
       relu >>S1 clamp127 -> int8, maxpool2x2 s2 -> 14x14x16 (fmap_a)
conv2 3x3 s1 p1, 16->16 ch  -> 14x14x16  acc32 + bias
       relu >>S2 clamp127 -> int8, maxpool2x2 s2 -> 7x7x16   (fmap_b)
fc    784->10, acc32 + bias -> scores[10] int32 (no requant)
```

Quantization contract (bit-exact, shared RTL<->python):

- conv input bytes: conv1 uint8 0..255; later layers int8 0..127.
- weights int8, biases int32. acc = bias + sum(x*w), int32 wrap-free (width 32).
- requantize: `q = acc < 0 ? 0 : acc; q = q >> S; q = q > 127 ? 127 : q` (S1=7, S2=7).
- pool: max over the 2x2 *quantized* bytes (equivalent to max-then-q since ops are monotonic).
- fc scores: raw int32, no shift.

## Engine structure (`src/cnn_engine.v` + helpers)

- 16 lanes x 9 signed INT8 MACs = 144 multipliers (DSP-mapped). Lane L computes
  output channel L.
- Per-layer loop: for each input channel `ic` (Cin passes):
  stream the ic-plane row-major through a 3-row line buffer; at every stream
  position the 3x3 window (zero-padded edges) is broadcast to all 16 lanes;
  each lane does 9 MACs with its w[L][ic][0:8] and accumulates into acc[L][pos].
  acc is a 512-bit-wide RAM (16 x int32), one RMW per valid position,
  pipelined read->add->write (positions are distinct, no hazard).
- Pool/readout: stream acc positions once; per position all 16 lanes quantize
  in parallel, then 2x2 maxpool via one row of pooling registers; write one
  128-bit fmap word (16 channel bytes) per pooled position.
- FC: stream fmap_b bytes (784) 1/cycle, broadcast to lanes 0..9; lane L
  consumes weights byte-serially (a 72-bit weight word every 9 cycles).
- CRC32 (IEEE, poly EDB88320, init/xorout FFFFFFFF) updated for every byte
  written to fmap_a, fmap_b (pos-major, channel order = byte lane order), then
  the 10 int32 score words little-endian. Single `digest` output.
- `cycles` counts from start to done.

### Memory map inside engine

- img_ram   1024 x 8b    : UART-writable input image (also $readmemh init)
- wmem[16]  128 x 72b    : per-lane weights (word = 9 int8, w0 in [7:0])
- acc       1024 x 512b  : 16 lane accumulators per position
- fmap_a    2048 x 128b  : conv1 pooled output (196 pos x 16 ch)
- fmap_b    1024 x 128b  : conv2 pooled output (49 pos x 16 ch)
- scores    10 x 32b regs

### Weight mem files (`cores/acceleration/cnn_inference/mem/`)

- `img.mem`   784 lines, 2 hex chars each (row-major bytes).
- `w1.mem`    16 lines x 18 hex chars (72b). Line L = lane L, ic0, w = {w8..w0} MSB->LSB.
- `w2.mem`    256 lines. Line L*16+ic = lane L, channel ic.
- `wfc.mem`   1408 lines. Line L*88+g = lane L, weight group g (9 weights; byte j = w[9g+j]).
- `bias.mem`  42 lines x 8 hex: 16 conv1 + 16 conv2 + 10 fc int32 biases (two's complement).
- `wmem.mem`  2048 lines x 18 hex: unified per-lane weight RAM, 16 lanes x 128 x 72b.
  Address L*128+w: w=0 conv1, w=1+ic conv2 (ic 0..15), w=17+g fc group g (g 0..87).
- `exp_fmap_a.mem` / `exp_fmap_b.mem` / `exp_scores.mem`: golden outputs for tb.
- `golden.json`: {seed, shifts, scores[10], digest, fmap_a_crc, fmap_b_crc}.

### Engine port contract

```verilog
module cnn_engine(
  input  wire        clk, rst_n, start,
  output reg         busy, done, err,
  input  wire        in_we,       // img write (idle only)
  input  wire [9:0]  in_waddr,
  input  wire [7:0]  in_wdata,
  input  wire [1:0]  rd_sel,      // 0 scores,1 fmap_a,2 fmap_b,3 img
  input  wire [11:0] rd_addr,     // word address (scores: 0..9; fmap/img: byte addr)
  output reg  [31:0] rd_data,     // scores->i32; fmap/img -> {24'b0,byte}
  output wire [31:0] digest,
  output wire [31:0] cycles
);
```

## UART protocol (115200 8N1, little-endian)

Request -> response. No unsolicited traffic except one boot banner.

| cmd | name | request bytes | response bytes |
|-----|------|---------------|----------------|
| 01  | PING | 01            | A5 01 '1' '3' '8' 'K' |
| 02  | LOAD | 02 ll hh <ll:hh bytes> | A5 02 00 |
| 03  | RUN  | 03            | A5 03 00 |
| 04  | STAT | 04            | A5 04 st c0 c1 c2 c3 (st: b0 busy b1 done b2 err) |
| 05  | RESC | 05            | A5 05 <40B scores> <4B digest> <4B cycles> |
| 06  | DUMP | 06 ss aaaa(ll) nnnn(ll) | A5 06 <n bytes> (ss: 0 scores,1 fmap_a,2 fmap_b,3 img,4 wmem[63:0],5 wmem[71:64]+bias@2048; addr/len in bytes) |
| 07  | SELFTEST | 07        | like RUN but uses current img_ram then RESC |

Boot: after reset the engine runs once on the $readmemh default image, then
prints `CNN138K BOOT D=XXXXXXXX C=NNNNNN\r\n` once and goes idle.

## Pinout

- clk P16; rst U4 (reads LOW on bare SOM — verified; used only as optional
  active-HIGH re-arm, POR releases unconditionally)
- uart_tx fan-out: P15 (primary), U16, V22
- uart_rx: **N16** (confirmed on hardware by gw5a138_rxprobe v2: bit91 of the
  157-pin sticky mask goes low exactly when host writes to COM25)

## Files

- `src/` top.v, cnn_engine.v, uart_rx.v, uart_tx.v (uart cores copied from comm_20k)
- `sim/` tb_cnn_engine.v (engine+mem vectors), tb_top_uart.v (full UART loopback sim)
- `mem/` generated by gen_mems.py
- `host/cnn138k/` cnn_model.py (golden), gen_mems.py, cnn_uart.py (verify)
- `scripts/` build_cnn_infer_138k.ps1, program_cnn_infer_138k.ps1, test_cnn_infer_138k_sim.ps1

## Bring-up status (hardware)

- UART RX pin = N16 (probed); TX = P15. `rst` (U4) reads LOW on the bare
  SOM, so the POR is unconditional and U4 only re-arms reset when HIGH.
- Engine: 3-stage MAC pipeline + 2-byte/phase CRC folding for timing
  margin; 14093 cycles per inference.
- wmem lives in distributed LUTRAM (same class as img_ram, verified on
  hardware) - the earlier flat combinational ROM mux was the main
  timing suspect.
