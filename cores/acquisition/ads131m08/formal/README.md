# ADS131M08 formal boundary harness

This directory contains a small SymbiYosys harness for the reusable IP. It
checks the contracts that can be proved without a behavioral ADS device model:

* FIFO level bounds, full/empty consistency, overflow stickiness and drop
  count monotonicity;
* AXI-Lite response stability while `BREADY` or `RREADY` is low;
* one active-low device select at a time;
* one-beat stream packet framing and stability under back-pressure.

The full cryptographic or analog-device behavior is outside this harness. A
passing proof must not be interpreted as board or side-channel verification.

## Exact commands

From the repository root, when SymbiYosys and Boolector are installed:

```powershell
sby -f cores/acquisition/ads131m08/formal/ads131m08.sby
```

The checked-in job is a 12-cycle bounded model check. It is useful for
catching boundary regressions, but it is not an unbounded induction result.

The source-level fallback, which checks that Yosys can parse and elaborate the
harness, is:

```powershell
yosys -p "read_verilog -formal -sv cores/acquisition/ads131m08/rtl/ads131m08_axi_lite.v cores/acquisition/ads131m08/rtl/ads131m08_sample_fifo.v cores/acquisition/ads131m08/rtl/ads131m08_spi_engine.v cores/acquisition/ads131m08/rtl/ads131m08_scheduler.v cores/acquisition/ads131m08/rtl/ads131m08_regfile.v cores/acquisition/ads131m08/rtl/ads131m08_stream_adapter.v cores/acquisition/ads131m08/rtl/ads131m08_multi_ip.v cores/acquisition/ads131m08/formal/ads131m08_formal_harness.sv; prep -top ads131m08_formal_harness"
```

The repository runner uses the bounded SymbiYosys job when the OSS CAD Suite
provides `sby` and Boolector. If either is unavailable, it executes the Yosys
elaboration fallback and records **DEFERRED**; elaboration is never labelled as
a completed proof.
