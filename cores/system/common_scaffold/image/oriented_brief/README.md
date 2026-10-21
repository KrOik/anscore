# Intensity-centroid orientation and rotated BRIEF

`oriented_brief_frame.sv` implements a complete stored-frame, keypoint-in, 256-bit descriptor-out core. It actually computes circular-patch intensity moments and rotates each sampling pair. It is not plain BRIEF relabelled ORB. It is also not a complete ORB detector/pyramid or OpenCV-bit-compatible descriptor: FAST, NMS, scale pyramid and smoothing are upstream responsibilities.

## Numerical contract

Static WIDTH/HEIGHT are positive, WIDTH*HEIGHT <=65536; BITS=8..12 and RADIUS=1..15. Default radius15 means a31-pixel diameter orientation patch. Within the circle dx²+dy²<=R², Mx=sum(dx*I), My=sum(dy*I). A serial Q7 direction search maximizes Mx*cos_q+My*sin_q over16 bins; tied maxima choose the smallest bin. Coefficients are [127,117,90,49,0,-49,-90,-117,-127,...]. `m_angle` k means k*22.5 degrees, positive x toward positive image y. Quantization boundaries use these Q7 vectors, not atan2 floating point. Nonzero-vector angular quantization error is conservatively <12degrees (analytic adjacent-direction boundary maximum11.633634degrees). Zero moments produce angle0 and orientation_valid0, but a valid descriptor (constant patch: all-zero descriptor).

Each of256 fixed seeded sample pairs is drawn from the radius-R integer disk. Each angle's offsets are rotated in the host generator and rounded to nearest integer, exact halves away from zero. Packed ROM has4096 24-bit entries; four signed6 offsets [ax,ay,bx,by]. Descriptor bit i is exactly image(a)<image(b), equality0; bit0 is the least significant bit. The whole square of radiusR+1 must fit the frame. Otherwise invalid1/zero descriptor and unchanged x/y/id are emitted. Even 65535 keypoint coordinates are rejected without wrapping.

All15 radius-specific ROMs are generated and frozen. Independent unrotated256-pair fixtures are packed24-bit `base_r1.hex` through `base_r15.hex`; the Python oracle decodes signed6 offsets and independently applies mathematical rotation. The default PATTERN_FILE automatically follows RADIUS. Custom ROMs must use the same entry packing and intended radius; RTL checks all rotated offsets against [-R-1,R+1] before any sample read and returns explicit invalid/zero descriptor/error3 on a bad entry. ROM-file resolution follows the repository root working directory unless PATTERN_FILE is overridden to an absolute path. There is no runtime pattern mutation interface.

## Streaming and lifecycle

All transfers are `rst_n && ce && valid && ready`. Reset is synchronous active-low and overrides CE. Capture exactly WIDTH*HEIGHT pixels, row-major; SOF only on first pixel, EOL only at each row end. Any marker violation aborts the partial frame, sets error_code1 and immediately permits a new full frame. No timeout/automatic SOF scanning exists. A good next pixel clears that diagnostic.

Once loaded, frame_available1 and s_ready0. Submit unlimited keypoints through kp_valid/kp_ready; output contains descriptor, angle, orientation_valid, invalid, x/y/id. Output and metadata remain stable under CE pause or backpressure. Only one keypoint is active. Release is accepted only when no descriptor is active; release has priority over a simultaneous keypoint and discards the frame. Frame/ROM RAMs are not reset; frame_available blocks stale contents. Reset aborts partial capture, in-flight orientation or pending output, requiring a fresh full frame.

error_code2 is an internal illegal-state recovery diagnostic; error_code3 identifies malformed custom ROM. Marker diagnostics persist until the next good capture beat. Custom-ROM diagnostics persist until a good capture beat; a corrupted ROM remains the caller's responsibility. No silent clipping or valid descriptor substitution occurs.

## Storage, latency, and verification

One synchronous pixel RAM, one synchronous pattern ROM; all image reads are registered, including centroid accumulation and descriptor pair reads. Serial orientation visits the(2R+1)² square in two enabled cycles per point, ignoring values outside the circle. Direction search is16*8 cycles, using shift/add multiplication and no DSP. Descriptor sampling consumes4*256 enabled cycles. Valid-keypoint output appears after 2*(2R+1)²+128+1024 enabled edges following acceptance; earliest consumption is the following enabled edge. Invalid-keypoint output appears immediately after acceptance. These are sequential-descriptor throughput claims, not II=1.

Commands from repository root:

```
python -B cores/system/common_scaffold/image/oriented_brief/run_tests.py
python -B cores/system/common_scaffold/image/oriented_brief/run_synthesis.py
```

The independent Python coordinate/moment/rotation oracle tests radius1/BITS8, radius3/BITS8, radius7/BITS10 and radius15/BITS12,264 descriptors over88 frames: all16 direction gradients, random/constant inputs and quarter-turn rotated textures. Quarter-turn orientation shifts and bit-identical descriptors are asserted. Testbenches exercise CE stalls, backpressure stability, invalid borders/65535 coordinates, frame marker errors and replay, release, deliberately corrupted custom-ROM rejection, reset during capture, active orientation and pending output. This does not constitute board, image-quality or feature-matching accuracy acceptance. The source comparison uses a distinct pattern and numerical contract, not OpenCV descriptor equality.

Isolated Gowin synthesis of40x40/BITS8/R15 uses6780 LUT-class cells (including290 MUX2_LUT5),752 FF,1 DPX9B+6 SP,0 DSP; `-noalu -nodsp`. No LUTRAM remains. Other geometries/bitdepths require their own resource check before board integration.
