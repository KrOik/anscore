# Standalone IP interface contract

`ads131m08_multi_ip` is a single-clock, synchronous IP. It exposes shared
ADS131M08 pads, a 32-bit single-beat AXI4-Lite control port, and one
AXI4-Stream beat per completed conversion frame.

AXI-Lite is deliberately minimal: no bursts or exclusive accesses, address and
data channels may arrive independently, and one response is outstanding per
direction. The current bridge returns `OKAY` for every transaction. `WSTRB` is
carried to the register block and is reserved for the documented compatibility
behavior; byte-write semantics are not yet a released feature (H-005).

`CTRL.W3` clears the software-visible IRQ and unmapped-write latches. The
underlying per-device timeout/identity/configuration flags remain visible in
`ERR` until the scheduler is restarted or reset; `CTRL.W4` owns FIFO flush and
overflow/drop clearing.

The stream uses `tvalid/tready` back-pressure. `tlast` is asserted on every
beat because each conversion frame is one packet. `tuser` carries device index,
frame sequence, ID/config status, and timeout status as described in the
register map. FIFO overflow drops the incoming frame and sets sticky status.

The 20K board wrapper is scalar and exists only for the one-device bring-up
top. The reusable IP remains vector-parameterised for `ADC_COUNT=1..16`.
