# Full AXI4 bounded NxM crossbar

`axi_multi_crossbar.sv` implements all five AXI4 channels with independent read/write round-robin arbiters. This is a full burst router, distinct from the AXI-Lite crossbar. Flat buses place port zero in the least significant slice; `port_schema.py` supplies the typed literal widths and directions used by tests; `port_schema.json` is ABI documentation only. The protocol test reads the standard `.vh` header `tb_protocol_body.vh`. Both executable inputs are covered by the global source snapshot.

Supported parameters: MASTERS/TARGETS 2..4, ADDR_WIDTH=32, DATA_WIDTH=32 or64, ID_WIDTH1..8, REGION_ADDR_BITS8..28. Default2x2/32bit/ID4/64KiB windows. Target t owns `[t*2**REGION_ADDR_BITS,(t+1)*2**REGION_ADDR_BITS)`. Forwarded addresses subtract the target base. Other address attributes are preserved. LOCK requests receive DECERR rather than sharing downstream exclusive monitors between masters with colliding IDs.

One transaction is outstanding per master per direction, and one per target per direction. Targets and read/write directions progress independently. Responses route by captured owner; original IDs are restored upstream. A source cannot submit its next same-direction descriptor until its previous response completes. Arbitration is fair among pending descriptors conditional on downstream progress; no timeout is imposed on stalled endpoints. WVALID may precede AWVALID, but WREADY remains low until a routed AW is accepted. Control admission incurs bubbles; this design does not promise one new transaction per clock.

FIXED1..16, INCR1..256, and aligned WRAP2/4/8/16 beats are supported. Narrow and unaligned FIXED/INCR transfers are routed transparently. Entire transfer byte spans must remain inside one window and one4KiB page, without32bit overflow. Reserved burst, illegal SIZE/WRAP, LOCK and unmapped addresses are rejected as whole requests. Rejected writes drain LEN+1 beats before one DECERR B; rejected reads return LEN+1 zero DECERR beats.

Downstream WLAST and upstream RLAST are regenerated from captured LEN. Bad source WLAST sets sticky `protocol_error` and upgrades successful B to SLVERR while preserving existing SLVERR/DECERR. Mismatched target BID/RID/RLAST sets sticky error; RID/BID are restored, RRESP and Rdata remain target supplied. Protocol errors do not synthesize missing beats or recover a target that stops early. CE gates only new upstream AW/AR admission; already accepted traffic continues. Reset is synchronous active-low and must be coordinated with both endpoint sides; it discards in-flight ownership and clears errors.

Run from repository root:

```powershell
python -B cores/system/common_scaffold/stream_bus/axi_multi_crossbar/run_tests.py
python -B cores/system/common_scaffold/stream_bus/axi_multi_crossbar/run_synthesis.py
python -B cores/system/common_scaffold/stream_bus/axi_crossbar_peer/test_five_channel.py
```

Own protocol tests cover three size profiles,256beat concurrent streams, same-target contention, response stability, whole-request errors, malformed framing/IDs, CE, simultaneous all-master round-robin admission, coordinated partial-transaction reset and11 invalid parameter declarations. Independent peer uses a per-beat byte-address oracle and physical five-channel endpoint drivers, including metadata, narrow STRB, WRAP,4KiB/region boundaries and four-master eight-round read/write contention. Reports bind source SHA. Pinned mature reference review is in `reference_review.json`; no external RTL is vendored.

Actual Yosys `synth_gowin -nodsp; check -assert` results: default2x2/32/ID4=1404 LUT-class, maximum4x4/64/ID8=5957 LUT-class, both0DSP/0BRAM. This is synthesis evidence, not timing closure or board validation. Integration, placement/routing and board acceptance remain parent-owned. Generated binaries/netlists live only in auto-cleaned C: temporary directories.
