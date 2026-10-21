# Common interface v1

All kernels use a single clock and enabled ready/valid transactions. These are
native transaction interfaces, not complete AXI bus controllers or physical
I2C/SPI/UART peripherals. Existing repository peripherals can feed them.

| Port | Direction | Meaning |
|---|---|---|
| clk | input | rising edge clock |
| rst_n | input | asynchronous active-low reset |
| clk_en | input | logical clock enable, shared with both endpoints |
| in_valid / in_ready | input / output | request present / request accepted |
| a, b, c | input | three 32-bit operation-specific request fields |
| out_valid / out_ready | output / input | response present / consumer accepts |
| result, aux | output | two 32-bit operation-specific response fields |
| fault | output | per-response error or diagnostic event, never silent discard |

Request transfer occurs on `clk_en && in_valid && in_ready` at a rising edge.
Response transfer occurs on `clk_en && out_valid && out_ready` at a rising
edge. Both endpoints must use this convention. When adapting to ordinary AXI
Stream, tie `clk_en=1`, or gate downstream ready/valid consistently; AXI
compatibility with an arbitrary independent clock enable is not claimed.

Every request produces exactly one response. Most kernels respond after one
enabled edge and have one elastic slot. `bcd8_encode` has two elastic stages
and responds after two enabled edges. Both can accept and retire on the same
edge, so II=1. While a response is blocked or CE is low, its valid bit, result,
aux and fault stay unchanged. CE low freezes all registers. A two-slot BCD
kernel may fill its empty first slot while the second is blocked; no pending
response changes and no accepted request is lost. The source must hold request
fields and valid until acceptance. Inputs are sampled only on acceptance.
Reset cancels any outstanding response and clears all internal state to zero;
no response to the cancelled transaction is emitted.

For stateful kernels `c[31]` restarts that kernel's history as part of the
accepted request. It is not an extra cycle. Other bits of c keep their
operation-specific meanings. Some faulting operations update state (e.g.
sequence tracking resynchronizes); others preserve it. Each SPEC defines the
behavior. `fault` is a functional diagnostic signal, not a security guarantee.

Every source is synthesizable Verilog compatible with `iverilog -g2012` and
`synth_gowin`. Combinational work precedes registered elastic stages. Actual
timing depends on the selected core and device. One-cycle functionality does
not by itself prove a requested physical frequency; only routed timing and
board evidence establish that.
