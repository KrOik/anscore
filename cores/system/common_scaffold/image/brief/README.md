# Serial runtime-pattern BRIEF descriptors

`brief_descriptor.sv` computes real BRIEF binary pixel-pair descriptors from a
stored grayscale frame. It is **plain, non-rotation-invariant BRIEF**, not ORB.
It does not detect keypoints, estimate orientation or smooth images. An upstream
Gaussian or box prefilter is recommended to suppress pixel-noise sensitivity.
It is not OpenCV BRIEF bit-compatible: OpenCV uses smoothedSum with its own
fixed sampling patterns and local smoothing. If that behavior is wanted,
the matching upstream smoother and sampling table must be supplied. Pattern
quality/learning and application-level matching are outside this core.

Repository-wide filename searches (including wave2 IP) found no existing
BRIEF descriptor equivalent before this new module was added.

Parameters: positive static WIDTH/HEIGHT up to 65535, with total frame pixels
WIDTH*HEIGHT <=65536, unsigned BITS=8..12,
DESC_BITS=128 or 256, patch RADIUS=0..31. Data processing is serial and bounded:
one synchronous frame RAM, one pair of synchronous staging/active pattern RAMs,
one comparator and descriptor registers. There is no DSP, divider or hidden
parallel frame read array.

## Pattern configuration and bit contract

Each pattern entry contains four signed 8-bit offsets ax,ay,bx,by relative to
the keypoint. Write every entry through pattern_valid/pattern_ready, then commit
with cfg_valid/cfg_ready. No reset default pattern is invented. A staging-valid
bitmap requires the complete 128/256 entries since reset. Commit synchronously
scans all offsets, rejects any outside [-RADIUS,+RADIUS], then copies the entire
pattern into active RAM. Successful commit takes 4*DESC_BITS enabled cycles;
cfg_done indicates the complete active pattern is ready. Invalid/incomplete
commits pulse cfg_error and preserve the previous active pattern.

Pattern/config writes are accepted only with no frame loaded and no partial
capture. Commit has priority over a pattern write; both precede first-pixel
capture. Once frame capture begins, the active pattern is frozen until explicit
frame release. Pending config/pattern requests cannot stall an in-progress
capture or keypoint processing. To update for another frame, release first,
then perform the configuration handshakes before starting capture.

Descriptor bit **i** is 1 iff pixel(kx+ax_i,ky+ay_i) is strictly less than
pixel(kx+bx_i,ky+by_i); equality emits zero. Entry zero is m_descriptor[0],
not the MSB. No contrast normalization or mean subtraction occurs.

## Capture, keypoints, borders and recovery

First capture exactly WIDTH*HEIGHT pixels, row-major, through s_valid/s_ready.
SOF must be exactly (0,0), EOL exactly the final column. A legal complete frame
sets frame_available; input pixels stop until the frame is released. Arbitrarily
many keypoints can then be submitted through kp_valid/kp_ready. Each result
preserves x, y and id. release_valid/release_ready discards the loaded frame
and returns to capture/config phase. Release is accepted only between keypoints
and takes priority over a simultaneous keypoint request.

The **entire square radius patch** must fit inside the frame, even if a supplied
pattern uses fewer edge offsets. A keypoint is invalid if x<R, y<R, x+R>=W or
y+R>=H (including coordinate overflow/65535 cases). Invalid keypoints produce
m_invalid=1 and an all-zero descriptor, with unchanged metadata. There is no
silent clipping or edge replication. A geometry smaller than a patch is legal
but all its keypoints will be invalid. RADIUS=0 permits identical-pixel patterns
and yields all-zero descriptors.

error_code: 1 incomplete pattern, 2 out-of-radius offset, 3 frame marker error,
4 out-of-range pattern index (for 128-entry mode). Configuration diagnostics
clear on a successful commit or next first input; cfg_error is a one-enabled-
cycle pulse. A frame marker error aborts capture, invalidates that frame and
returns to idle while preserving the active pattern. Discard remaining beats
from the malformed frame externally and restart with fresh SOF. A stale partial
frame is never available for keypoints. No timeout or automatic SOF search is
implemented.

All transfers require **ce && valid && ready**; neighbors must honor CE. Output
descriptor/metadata/invalid/valid remain stable while paused or backpressured.
Reset is synchronous active-low and overrides CE, aborts pending output and
frame capture, clears the pattern-valid bitmap and requires a new full commit.
While reset is asserted, input valid signals are ignored and no transfer may
be counted, even if a combinational ready output is high. Producers must hold
valid low during reset and begin handshakes only after reset is deasserted.
RAMs are not reset; readiness and frame_available prevent stale reads.

## Storage, cadence and evidence

Storage bits are WIDTH*HEIGHT*BITS + 2*DESC_BITS*32, plus two descriptor-width
registers and the staging-valid bitmap. After a valid keypoint handshake,
output valid appears 4*DESC_BITS+1 enabled edges later; its earliest handshake
is the next edge. Minimum valid-keypoint initiation interval is 4*DESC_BITS+3
enabled cycles. Invalid keypoints present registered output immediately after
acceptance and can be consumed on the next enabled edge. This is intentionally
sequential and makes no II=1 descriptor claim.

```
python -B cores/system/common_scaffold/image/brief/test_brief.py
python -B cores/system/common_scaffold/image/brief/synth.py
```

An independent Python coordinate/pair oracle verifies 90 descriptors across
8/10/12-bit data, 128/256 bits, odd rectangular/1x1 geometries and radii 0/2/3.
Patterns include identical pixels and signed offsets; constant, random and
gradient frames exercise bit order. Tests cover valid/invalid corners and
65535 coordinates, incomplete/illegal pattern rejection and retained replay,
pattern replacement between frames, blocked mid-frame config snapshots,
marker-error recovery after partial capture, random CE/ready pauses, stable
stalled output, release and reset aborting a pending descriptor with CE low.
Four illegal parameter configurations are rejected. The 65536-pixel product
boundary (256x256) is accepted in an elaboration-only test; 257x256 and
65535x65535 are rejected. Pixel products are computed as unsigned 64-bit before
declaring RAM, and invalid geometries clamp the declaration to one entry before
the fatal guard, avoiding overflowing 32-bit address/memory declarations.
Temporary binaries are
automatically removed; small evidence and synthesis logs remain.

Isolated 16x16/8-bit/RADIUS3 Gowin synthesis (`-noalu -nodsp`):

| descriptor | LUT1-4 | MUX5 | FF | memory | DSP |
| --- | ---: | ---: | ---: | --- | ---: |
| 128 | 1331 | 131 | 658 | 1 DPX9B + 2 SDPX9B | 0 |
| 256 | 2094 | 203 | 1042 | 1 DPX9B + 2 SDPX9B | 0 |

Both CHECK passes report zero problems. Wide descriptor outputs are intended
for internal integration, not a claim of a physical external-pin interface.
No P&R, clock target, board or feature-matching quality evidence is claimed.

Design comparison was checked through an actual HTTPS fetch of
[OpenCV brief.cpp](https://raw.githubusercontent.com/opencv/opencv_contrib/4.x/modules/xfeatures2d/src/brief.cpp).
`reference.json` records the retrieved SHA256. It confirms OpenCV's PATCH_SIZE48,
KERNEL_SIZE9 and smoothedSum design; no implementation or sampling table was
copied. No upstream Gaussian-to-BRIEF integration is claimed by these tests.
