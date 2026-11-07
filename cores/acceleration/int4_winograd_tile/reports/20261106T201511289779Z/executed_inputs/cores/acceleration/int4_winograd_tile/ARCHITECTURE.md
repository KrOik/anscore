# Integer Winograd tile architecture

Status: RTL_CANDIDATE, INTEGRATION_CANDIDATE, HW_UNVERIFIED. No model,
AST, compiler, simulator, synthesis, PnR, STA, board test or PPA run has
executed for this package. Baseline: c9117a22459e954d496dfa66dd94d6f67188c862.

The independent capability is an exact F(2x2,3x3) transform-domain tile
cross-correlation. Existing int4_conv3x3_frame performs direct 3x3 products
through int4_weight_matvec. This module shares a 4x4 input transform among
resident output kernels. It is a tile engine, without a raster window or
multi-input-channel accumulator. These remain caller responsibilities.

## Choice and arithmetic

No target device, MHz or task-rate requirement was supplied. Choose one
signed11 x signed8 product operator, with registered synchronous operands
and a following product-write cycle, instead of sixteen parallel products.
Each kernel needs 16 transform-domain products for four spatial outputs,
versus 36 direct signed9 x signed4 products. The wider operators, transform
additions, publication cost and larger weight memory prevent inferring a
PPA or throughput advantage from that count alone.

The consistent transform variant is:

```
BT = [1 0 -1 0; 0 1 1 0; 0 -1 1 0; 0 -1 0 1]
Gp = [2 0 0; 1 1 1; 1 -1 1; 0 0 2] = 2G
AT = [1 1 1 0; 0 1 -1 1]
U4 = Gp g Gp^T, V = BT (d-xzero) B
Y4 = AT (U4 .* V) A
Y = Y4 / 4, acc = bias + Y
```

Integer arithmetic makes Y4 exactly divisible by four. There is no internal
rounding or saturation. The independent model will calculate direct spatial
cross-correlations and separately check the transform identity.

| Node | Stored signed width | Proven or conservative bound |
|---|---:|---|
| d-xzero | 9 | -255..255 |
| first input transform | 10 | -510..510 |
| V | 11 | -1020..1020 |
| raw g | 4 | -8..7 |
| first Gp transform | 6 | -24..22 |
| U4 | 8 | absolute value <=72 |
| product | 19 | full 11x8; actual absolute value <=73440 |
| first inverse | 21 | sum/difference of at most three signed19 values |
| second inverse | 23 | sum/difference of at most three signed21 values |
| spatial dot | 23 scratch width | absolute value <=9*255*8=18360 |
| bias plus dot | 33 | signed32 bias plus bounded dot |

All narrow operands are explicitly sign extended before add/shift. Scratch
storage intentionally has combinational multiway reads; it is small and
is not described as inferred block RAM. Kernel RAMs use one scheduled read
per memory and do not rely on same-address read/write collision behavior.

## Storage and schedule

Resident payload per row is 9x4 raw weights, 16x8 transformed weights and
61 metadata bits (bias32, scale16, shift5, zero8): 225 bits/row. At default
8 rows this is 1800 payload bits; at 64 rows it is 14400. Validity adds 11
bits/row. Payload RAM is not reset; validity prevents any uninitialized read.
Single-port low-depth memories may map to LUT RAM/FF rather than BRAM.
The small transform scratchpads total 36+72+144+160+176+304+168+132=1192
bits, excluding operand/control registers. No external RAM, ROM initialization,
vendor primitives or CDC are required. Resource risk: LOW for capacity,
MEDIUM for scratchpad mux/add paths; actual mapping/timing UNKNOWN.

Publishing a complete row reads nine raw taps in 18 cycles, computes twelve
first-transform values in 12 cycles, then writes sixteen transformed weights
in 16 cycles. Successful publish reply becomes visible 46 edges after config
acceptance. A held reply freezes new commands/configuration.

After a legal command, precheck costs rows cycles, input takes sixteen
handshakes, and two input transforms take 32 cycles. Each row takes 1 metadata
load + 32 operand-read/product cycles + 8 first inverse + 4 second inverse
+ 4 output handshakes = 49 cycles with continuously ready output.
With continuous input and output readiness, last raw output retires
48+50*rows edges after command acceptance; final response can retire at the
next edge. Backpressure/input gaps add their actual waits; no unconditional
completion bound exists. Commands do not overlap and tiles are not pipelined.
Runtime row/tile/loop counters use explicit bounded vectors. Products use
one logical operator; physical DSP count and power have not been measured.
