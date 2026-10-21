# Multi-initiator AXI4-Lite crossbar

Original synthesizable multi-initiator by multi-target AXI4-Lite fabric. Repository search located `sb_axil_crossbar_placeholder` (its legacy name describes a real one-initiator address fabric) and `sys_axi_lite_interconnect`, both one-initiator designs; this new core provides missing multi-initiator ownership/arbitration. Existing cores and their contracts are untouched.

## Interface

`axil_multi_crossbar #(MASTERS=2,TARGETS=4,ADDR_WIDTH=16,DATA_WIDTH=32,REGION_ADDR_BITS=ADDR_WIDTH-3)` has `clk,rst_n,ce` plus flattened standard `s_axil_*` and `m_axil_*` channels. Each upstream vector packs MASTERS entries and downstream vector TARGETS entries. Entry index0 occupies least-significant bits. Address width is ADDR_WIDTH, PROT3, response2, data DATA_WIDTH and strobe DATA_WIDTH/8. Standard AWADDR/AWPROT/AWVALID/AWREADY, WDATA/WSTRB/WVALID/WREADY, BRESP/BVALID/BREADY, ARADDR/ARPROT/ARVALID/ARREADY, RDATA/RRESP/RVALID/RREADY channels are present. There is no burst/ID/last/abort interface in AXI4-Lite.

Legal parameters: MASTERS1..4, TARGETS1..8, ADDR_WIDTH4..32, DATA_WIDTH32 or64, REGION_ADDR_BITS1..ADDR_WIDTH. Invalid static configurations fail closed: all upstream new-request READY stay0, with no accepted request or generated response. There is no out-of-band configuration error port. Use legal static parameters in a system; this behavior is tested for invalid dimensions rather than silently aliasing unsupported configurations.

## Address map

Uniform windows of 2**REGION_ADDR_BITS bytes start at address0. `target = address >> REGION_ADDR_BITS`; target indices greater than or equal to TARGETS are unmapped and return DECERR (2'b11) without target dispatch. A read DECERR returns data0. Routed target addresses retain low REGION_ADDR_BITS and zero high bits. PROT and WSTRB are passed unchanged. The default16-bit map has 8 potential windows of8192 bytes, four implemented and four holes. Setting REGION_ADDR_BITS=ADDR_WIDTH yields one whole-address-space window at target0 (other targets unreachable by configuration). This core does not implement arbitrary base/mask decode, permissions, width conversion, timeout or retries.

## Ownership and flow

Each initiator has one independent read transaction and one independent write transaction outstanding. AW and W use separate per-initiator holding registers and may arrive in either order or many cycles apart. They are paired only within that initiator. A target write is dispatched after both pieces exist; its AW and W then handshake independently and remain stable while stalled. Target B is accepted after both target channels retire. Responses are stored in per-initiator registers with their original owner. A held upstream B/R cannot be overwritten. Its initiator cannot accept a new transaction in that direction until response consumption. The same initiator's read and write directions remain independent.

Each target separately arbitrates reads and writes with round-robin selection. Different targets can execute concurrently, and read/write to the same target can execute independently. Each target direction has one in-flight owner. Its round-robin pointer advances to the slot after that owner when its downstream response is captured; at that point the target may serve another initiator even while the previous initiator holds its already buffered response. A permanently stalled target or missing downstream response can block that target direction indefinitely; no timeout or abort cancels an accepted AXI transaction. Other targets/directions remain available. Continuously eligible contenders under responsive targets/consumers are bypassed by at most MASTERS-1 other grants. Bounded wall-clock latency is not claimed without target timing assumptions.

## CE and reset

All AXI response and downstream ready/valid handshakes run on every clock. CE gates only acceptance of **new upstream AW/W/AR requests**, by masking their READY signals. Buffered requests continue to arbitrate, dispatch, receive responses and retire upstream responses while CE=0. A partly accepted write waits for its missing upstream AW or W, whose new-request handshake still requires CE=1. Never qualify downstream or response handshakes with CE. Every exposed valid payload holds until its true AXI handshake.

Reset is synchronous active-low, has priority over CE, and clears all outstanding state and exposed VALID signals. It is a coordinated global reset: targets and initiators must also reset or otherwise flush their transactions. Resetting this fabric alone in the middle of a live AXI transaction is not supported as a transparent cancellation protocol. No other operation cancels accepted traffic.

## Evidence and commands

```
python -B cores/system/common_scaffold/stream_bus/axil_multi_crossbar/run_tests.py
python -B cores/system/common_scaffold/stream_bus/axil_multi_crossbar/test_fairness.py
python -B cores/system/common_scaffold/stream_bus/axil_multi_crossbar/test_parameters.py
python -B cores/system/common_scaffold/stream_bus/axil_multi_crossbar/test_reset.py
python -B cores/system/common_scaffold/stream_bus/axil_multi_crossbar/synth.py
```

Main independent behavioral scoreboard: six profiles2x4/32,4x8/64,3x3/32,1x1/32,1x8/64,4x1/64 and1440 total read/write transactions. Independent initiators delay AW/W in arbitrary order, independently issue reads, randomly stall B/R; targets independently stall AW/W/AR and delay B/R. Every response owner/value/SLVERR/DECERR, local target address, PROT and WSTRB is checked. The target scoreboard verifies AW and W originate from the same initiator/transaction. All downstream held request channels and upstream held responses are checked. CE-off real response handshakes and concurrent busy targets are required. Initial shared-target contention and subsequent distributed targets are both exercised. The behavioral target response formula is independent of RTL internal owner registers.

Fairness:128 transactions with four continuously requesting initiators contending the same target, exact repeated0,1,2,3 grant order checked independently in read and write directions. Parameter:3 legal boundary profiles including ADDR4/32, full-width decode and64-bit data;8 invalid static configurations fail closed. Directed legal tests capture W before AW, stall AW/W separately, then keep CE0 through downstream dispatch/response and upstream response retirement, preserving64-bit data and PROT. Reset:partial AW-only/W-only, stalled exposed target requests, held upstream responses and synchronous reset at CE0, clean recovery/no phantom transactions.

Isolated Gowin `synth_gowin -nodsp; check -assert` passes:

| Masters x targets | Address/data | LUT-class | DSP | Conservative BRAM9 |
|---|---|---|---|---|
|2x4|16/32|805|0|0|
|4x8|32/64|7910|0|0|
|3x3|16/32|1077|0|0|
|1x1|4/32|82|0|0|

LUT-class includes LUT+ALU+MUX+4*RAM16SDP4; every block RAM primitive would count as2 BRAM9, including SP/SPX9. No block memories are used. These are isolated mapped results, not routed timing or board validation. Board integration and delivery acceptance must be assessed separately.

Three mature verilog-axi references (`axil_crossbar_wr.v`, `axil_crossbar_rd.v`, `arbiter.v`) were actually retrieved at a pinned commit; references.json includes source URL/SHA256/byte count/access time/excerpts. Only architectural comparison was used, and this narrower original implementation does not claim the reference core's full buffering/features. Retrieved source exists only in process memory. All generated simulators/fixtures/synthesis intermediates use TemporaryDirectory and are automatically cleaned. Persisted logs and JSON evidence are retained. source_freeze.json binds code/tests/docs/references; final_validation.json binds current source and reports.
