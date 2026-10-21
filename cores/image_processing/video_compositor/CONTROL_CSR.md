# Integrated scanout control

`rtl/video_control.v` combines three raster_osd_output lanes and the held
result CSR. The transport-neutral interface has a10-bit byte address and one
outstanding response. The low256bytes are RESULTS_CSR.md unchanged; lane
control banks are100,200,300. All producers/CSR use one clock.

| Lane offset | Function |
|---|---|
| 00,04,08,0c | Horizontal active/front/sync/back |
| 10,14,18,1c | Vertical active/front/sync/back |
| 20 | Pixel tick divider1..65535 |
| 24 | Finite run target frames1..65535 |
| 2c | Status bits0 ready,1 running,2 timer done,3 timing error,4 overflow,5 config pending |
| 30 | Write full word1=start,2=stop,4=abort |
| 34 | Read active configuration version |
| 38 | Write full word1=commit layer configuration |
| 40..5c | Write8shadow layer words (SPEC raster_osd_output map), byte strobes supported |
| 60 | Read number of produced CRC results in the current/last run |
| 64 | Read source completed-raster frame counter |

Timing/divider/target writes require idle ready and all strobes, values0..65535
(divider and target cannot be0). Timing core validates geometry at start,
including nonzero active/sync and maximum totals. Invalid geometry reports
timing error, produces no CRC and must not be treated as a successful run.
Hsync positive/vsync negative are fixed in this reference controller.
Layer writes may run concurrently; commit retains the existing boundary-safe
application policy. Reads of shadow layer words are unsupported (CSR error).
Start requires idle, no pending commit, and at least one committed version.
Stop/abort are frame-boundary operations as described in SPEC; neither is
an emergency asynchronous blanking signal.

The controller requests stop during the final requested source frame, so a
finite run ends at the correct total-raster boundary. Pixel tick dividers are
independent; start resets the lane's phase and produced-result counter.
Wait for ready and verify produced count, errors, CRC and drop counters;
timer done is transient and is not the result-completion handshake. Ready
also waits for six pixel pipeline stages to drain. Result mailboxes retain
their first unacknowledged result and report subsequent drops. ACK old results
before starting a run if a new first-frame snapshot is needed; starting does
not silently ACK or reset cumulative drop counters.

```
. ./scripts/env.ps1
python cores/image_processing/video_compositor/tools/test_control.py
```

The test exercises actual requests/responses into all three raster pipelines,
finite three-frame runs, runtime lane0 layer commit, exact first-frame zlib
CRC/readbacks, two drops per lane, explicit ACK and second one-frame runs
without reset. Additional checks reject zero-width geometry with no result,
repair the configuration,abort a ten-frame run at its first frame boundary,
and verify a clean one-frame restart. No UART,hard user-JTAG,physical display
or25K P&R is implied by this simulation.
