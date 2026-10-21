# ISP statistics to AE bridge

`ispstats_ae_bridge.sv` connects the existing `ispstats_stream` **CH=1** result
RAM to `img_ae_controller`. It sums 1..64 zone records into frame luminance,
pixel count and overexposure count. RGB records cannot be used as luminance:
convert RGB to grayscale before the meter or supply a separate luma meter.

Configure the meter normally and connect its `res_data`, `res_bank`, `res_addr`,
`res_done`, `res_new` and `res_new_bank` ports. On `res_new`, provide the completed
bank's `res_count` slice as `frame_records`, an application frame identifier
as `frame_id`, and any frame-integrity error as `frame_error`. AE reserves
frame ID `FFFFFFFF` for configuration updates, so use other IDs for frames.
Width parameters must match the meter's CNTW/SUMW/ENW. The bridge reads each
record using the meter's synchronous read latency and takes two clocks per
record. It must run continuously; do not gate its clock with AE's `clk_en`.
AE `stats_ready` already incorporates CE and backpressure.

Outputs stay stable until `stats_valid && stats_ready`. Only one pending frame
is buffered. New frame notifications while busy are dropped and explicitly
reported in sticky `overrun` and modulo-2^32 `dropped_frames`. A new event can
be accepted on the same clock that a completed output is consumed. Invalid
record counts, invalid/reused RAM banks, invalid zone counts, excessive saturated
counts and arithmetic overflow set `stats_overflow`; AE then reports an error
without changing actuators. No complete result is silently replaced. Reset
aborts pending measurements and clears diagnostics; reset the connected meter
and AE at the same time.

The source RAM retains a completed bank for one following frame. The producer
must preserve that existing contract; the bridge diagnoses observed bank
invalidation/reuse and does not add a third frame buffer.

From the repository root:

```powershell
python cores/system/common_scaffold/image/ae_stats_bridge/run_tests.py
```

Tests cover 45 independent generated zone-sum cases (including 64 zones and
illegal records), output stalls, bank invalidation, event overrun and reset.
An end-to-end test instantiates the actual meter, bridge and AE: six grayscale
pixels produce sum=605, count=6, saturated=2, mean=100 and exposure=8. CE stalls
the AE while the bridge drains the result RAM. Logs and source hashes are stored
in unique evidence folders; temporary simulation binaries are automatically removed.
This is local functional evidence, with no P&R, board or physical camera claim.

Isolated synthesis is available with `python cores/system/common_scaffold/image/ae_stats_bridge/synth.py`.
Default-width Gowin synthesis passed `check -assert`: 386 LUT1..4, 66 MUX2_LUT5,
196 FF, no DSP or RAM. This count excludes the meter and AE controller.
