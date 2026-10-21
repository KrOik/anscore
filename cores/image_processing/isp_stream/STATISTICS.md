# Frame statistics integration

`rgb_frame_statistics.v` reuses the canonical `img_isp_awb_stats.v` unchanged.
Its one-stage elastic RGB path preserves SOF/EOL and adds aligned EOF/frame ID.
Only accepted input pixels enter sums and counts. Accepted EOF blocks new input
until the canonical collector accepts an explicit flush. Snapshots hold their
source frame ID, RGB sums, pixel/line counts and overflow under backpressure.
Malformed framing sets a sticky protocol error; reset discards partial state.

`isp_stream_with_statistics.v` composes the existing RAW-to-color core with this
stage. A successful command response waits for final output EOF acceptance and
statistics publication. Snapshot consumption is independent of response
consumption, but a pending snapshot blocks the next command. Statistics are
exposed only for a successful core response. An errored frame drains accepted
pixel output before responding, then resets the statistics collector; its
snapshot is suppressed. Pixels already emitted from an errored frame are not
revoked and must be discarded by the consumer using the error response.

Run after sourcing `scripts/env.ps1`:

```powershell
python cores/image_processing/isp_stream/tools/test_statistics.py
python cores/image_processing/isp_stream/tools/test_isp_statistics.py
python cores/image_processing/isp_stream/tools/test_isp_stats_recovery.py
```

Standalone evidence `statistics_20261020T173108154399Z`: SUM_WIDTH 48 and 8,
each 384016 pixels/four snapshots, 1x1/5x3/320x240/640x480, exact Python sums,
counts and tags, snapshot/pixel backpressure, narrow-sum saturation/overflow.
Recovery evidence `stats_recovery_20261020T174054518375Z`: malformed EOL,
held output during fatal drain, 18 exact output pixels across two frames,
no malformed-frame statistics, clean-frame sums 225/225/225 and counts 9/3.
The successful snapshot is held for 30 cycles after frame response consumption;
new command admission remains blocked until its independent handshake.

Full-chain evidence `isp_statistics_20261020T173832627433Z`: RAW8/10/12 each
380685 final RGB pixels and seven snapshots PASS, including 320x240 and
640x480 input, exact independent Python pixel values/metadata and per-frame
RGB sums/counts/IDs. This also exercises frame configuration changes, gamma
reloads, randomized source/output stalls and invalid-dimension recovery.

This is functional simulation evidence. Sustained frame rate, physical PPA,
Sobel integration and 25K physical qualification remain open.
