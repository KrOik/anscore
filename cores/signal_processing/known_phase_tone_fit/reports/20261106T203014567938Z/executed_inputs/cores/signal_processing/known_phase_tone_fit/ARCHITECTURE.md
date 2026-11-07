# Architecture and resource budget

One command owns one window and one result. The controller accepts a sample,
evaluates its phase with one unchanged iterative CORDIC, and serializes five
exact products into eight sufficient statistics. It retains no sample window.
After the last beat, sixteen more products form centered statistics, the common
determinant, and the two scaled numerators. Division belongs to the consumer.

The sample products are cc, ss, cs, xc, xs. The final paired products are
N*CC/C*C, N*CS/C*S, N*SS/S*S, N*XC/X*C, N*XS/X*S,
A*D/B*B, u*D/v*B, and v*A/u*B. A single signed113 first-product register is
reused for each pair. Five final diagnostics/right-hand sides use signed56
registers. The output register retains the full result under backpressure.

There is one actual `stream_sincos` instance and one actual
`img_hist_serial_multiply` instance. The latter uses unsigned56x56 operands,
56 carry-save iterations and14 byte-carry fold iterations per product. The core
restores signs around this unchanged unit. There are no new data-dependent
`*` or `/` operators, inferred multiplier array, sample RAM, or external IP file.

A conservative source-derived compute budget is at most400*N+1500 clocks per
valid complete window once its beats are available, plus source gaps and sink
stalls. Per sample the CORDIC takes20 rotations plus handshakes, and five
products take70 work clocks each plus their handshakes. Sixteen final products
fit within the1500-clock allowance. Rank-deficient windows stop after delta.
At a hypothetical50MHz,400 clocks per sample corresponds to125ksample/s before
the final-window overhead. This is arithmetic budgeting, not measured frequency
or an input acceptance-rate claim. Ready deasserts during each sample's work.

Explicit register inventory, including both reused instances, is below4096
bits at MAX256/TAG32. The top has448 statistics bits,280 Gram/RHS bits,
113 first-product bits, at most612 output bits, and under160 remaining state,
sample, phase, and basis bits (<1613 total). The multiplier has four112-bit
vectors,56 multiplier bits,112 output bits, plus state/count/control (<640).
The CORDIC has two26-bit vectors,32-bit angle,36 output bits, and small
state/tag/count (<160). Total is conservatively below2413, leaving headroom
inside4096. This is a source register inventory, not a synthesis cell count;
combinational adders, muxes, fanout, routing, and control timing are not counted.

Resource risk: MEDIUM. Latency risk: HIGH because products are serialized.
Physical fit/timing/power: UNKNOWN. No prior helper qualification transfers to
this integration, and no synthesis, PnR, STA, board or PPA result is claimed.
