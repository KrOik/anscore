# Three-output result snapshot CSR

`rtl/video_results_csr.v` uses the existing one-outstanding request/response
interface (8-bit byte address,32-bit data,4 byte strobes). All producers and
CSR share one clock. Responses hold data/error/valid under backpressure;
no second request is accepted until the prior response is consumed.

| Address | Read |
|---|---|
| 00 | Magic56494431 |
| 04 | Occupied bits2:0 |
| 08,0c | Build ID low/high |
| a0,a4,a8 | Live dropped-result count for lanes0,1,2 |

Write10 with all four strobes and nonzero mask1..7 ACKs the selected slots.
ACKing an empty slot is allowed. Other writes/masks/strobes are rejected.
Each lane owns a32-byte read-only slot at40,60,80:

| Offset | Field |
|---|---|
| 00 | Frame ID |
| 04 | CRC32 |
| 08 | Active pixel count |
| 0c | Error byte |
| 10 | Configuration version low13bits |
| 14 | Number of captured results since reset |
| 18,1c | Capture system-clock timestamp low/high |

Reading an empty slot errors. Invalid/unaligned addresses error. Reads are
snapshots of state before that request's edge. Slot fields remain unchanged
while occupied, until explicit ACK. A result arriving while occupied is
dropped and increments a separate live per-lane counter; it never overwrites
the host-owned record. Simultaneous ACK/new result replaces atomically without
incrementing drops. The new slot is occupied immediately, so after ACK the
host must inspect occupancy instead of assuming it is empty. Captured serials
count accepted snapshots, not all produced frames. Counts wrap modulo2^32;
timestamps modulo2^64. Reset clears slots,counts,timestamps and pending response.

`raster_osd_output.crc_version` is latched alongside the CRC's accepted LAST;
connect this to the mailbox producer version, not the live config_version.
Transport integration, run control and producer-to-CSR top-level wiring remain
open. The mailbox cannot backpressure a physical raster and is not a frame FIFO.

```
. ./scripts/env.ps1
python cores/image_processing/video_compositor/tools/test_results_csr.py
python cores/image_processing/video_compositor/tools/test_raster_osd.py
```
