# Synthesizable virtual RAW source and frame pacing

`virtual_raw_source.v` supplies command, RAW payload and response handshakes to
the ISP. A run latches width, height, frame count, period and seed. Subsequent
pin changes do not affect it. The sample at (x,y) in frame f is
`(seed+23*x+37*y+57*f) mod 2^RAW_BITS`. Incremental additions implement this
without a multiplier or frame buffer. RAW8/10/12 are tested.

Frames start only after command acceptance and finish only after the response.
SOF/EOL/EOF follow accepted coordinates; all offered samples hold under
backpressure. If the consumer completes on time and immediately accepts each
offered command, command-to-command spacing is exactly period_cycles. At
50MHz,1666667 clocks is approximately30fps. Late completion stretches the
interval; the source does not drop pixels or pretend to maintain cadence.
Widths/heights/count must be nonzero and period must be at least two clocks.
An invalid run finishes with error and no frames. Done/error hold until restart
or reset. A nonzero response error finishes the run,including a pre-payload
configuration rejection. Such an explicit error handshake aborts the offered
frame and may withdraw its unaccepted RAW pixel; it does not wait indefinitely
for the rejecting consumer to resume. Ordinary backpressure still holds pixels.
External reset also aborts a run.

Counters: completed_frames includes error responses; deadline_misses counts
responses received more than period clocks after command acceptance.
command_stalls counts offered-command wait cycles; pixel_stalls counts offered
pixel wait cycles. run_cycles counts active clocks through gaps. Counters wrap
32 bits except the internal age timer, which saturates. Frame IDs wrap16 bits.
Command waiting is reported separately and is not included in deadline_misses.
There is no watchdog if the consumer stops permanently.

Reuse decision: existing `csr_capture_replay`/`loaded_fabric_replay` remain
unchanged for host-loaded streams. They neither implement the RAW raster
command/response contract nor periodic frame generation, so this small source
adds the missing controlled-input function rather than replacing that asset.

After sourcing scripts/env.ps1:

```powershell
python cores/image_processing/isp_stream/tools/test_virtual_raw_source.py
python cores/image_processing/isp_stream/tools/test_realtime.py
```

Current-source evidence after early-error handling:
`virtual_source_20261020T180856909397Z` PASS RAW8/10/12.
Each width checks all samples and markers: four7x5frames at period200,
seven5x3frames with random command/pixel stalls and forced period2 (all seven
deadline misses recorded),three320x240frames and two640x480frames at period
1666667 with exact command cadence and zero misses. Restart/config-latching,
held-pixel stability and invalid configuration are checked. These source-only
tests do not prove that the actual ISP can sustain the requested rate.

`test_realtime.py` connects this source to the actual RAW10-to-Sobel pipeline,
with three320x240frames then two640x480frames, independent full-image Python
pixel/statistics golden and exact command cadence assertions. It tests finite
simulation at a50MHz clock and alternates Sobel/center bypass by frame ID.
Terminal evidence `realtime_20261020T175818964103Z` PASS: exact1666667-clock
command cadence,zero deadline misses/command stalls,829200 final output pixels
and five RGB statistics snapshots match independent Python golden.320x240
three-frame run3486953clocks;640x480 two-frame run2281086clocks (includes
inter-frame pacing,ends when final response completes). Pixel stalls230394
and614396 respectively are genuine pipeline backpressure,not dropped pixels.
This finite simulation does not establish routed50MHz or physical25K acceptance.

After the early-error source fix,the current-source full rerun
`realtime_20261020T180857788673Z` also terminalPASS with the same cadence,
829200exact output pixels and five RGB snapshots. Session65573 completed.
