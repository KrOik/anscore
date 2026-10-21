# Quantized single-scale grayscale Retinex

`retinex_ssr.sv` implements a fully hardware single-scale Retinex variant with
a fixed 5x5 binomial surround and public signed logarithmic output. It is not
multiscale Retinex (MSR), MSRCR, color restoration, automatic exposure, or an
adaptively selected Gaussian scale. The mathematical principle is log input
minus log local illumination; this core explicitly quantizes that principle.

## Exact arithmetic contract

Let `k=[1,4,6,4,1]`. Border sampling uses OpenCV REFLECT_101 independently in x
and y; an axis of length one degenerates to replication. Define:

```
S = sum(k[j]*k[i]*input[reflect(y+j-2),reflect(x+i-2)])
surround = floor((S + 128)/256)
L[v] = floor(256*log2(v+1) + 0.5)
raw = L[input[y,x]] - L[surround]
delta = sign(raw)*floor((abs(raw)*gain + 32768)/65536)
output = clamp(offset + delta, 0, 2^BITS-1)
```

The fixed binomial weights sum to 256, approximating a Gaussian surround of
scale roughly one pixel. Integer surround uses half-up rounding. The checked-in
4096-entry ROM stores nearest Q8 log2 values, with ties rounded upward; its
address is the unsigned intensity, so address zero contains log2(1)=0. ROM reads
are synchronous, with one shared read port. `m_raw` is signed 16-bit Q8 log2
difference, range bounded by +/-3072 for 12-bit input. Subtraction has no further
rounding. `m_surround` exposes the actual quantized integer surround.

`cfg_gain` is unsigned UQ8.8 **output intensity units per log2 unit**. `cfg_offset`
is signed 16-bit integer intensity offset. Final mapping rounds halves away
from zero, then saturates to the unsigned pixel range. A 16-enabled-cycle
shift/add multiply implements mapping without a general multiplier or divider.
Default gain256 means only **one output intensity unit per log2 unit**, and
default offset0 therefore produces small values. A useful explicit 8-bit display
example is gain8192 (=32*256), offset128. Enhancement mapping is application-
selected; the raw output allows a later controller or tone mapper to replace it.

## Interface, frame atomicity and recovery

Parameters: BITS8..12; WIDTH/HEIGHT1..4096 and total pixels <=65536. `LOG_FILE`
defaults to `cores/system/common_scaffold/image/retinex/log2_q8.hex`, relative to
the process working directory. Run the provided scripts from the repository
root, or override LOG_FILE for another integration directory. The ROM is a
required source asset; simulation and FPGA synthesis use the same values.

All handshakes require `rst_n && ce && valid && ready` at the rising edge. Reset
is synchronous, overrides CE and aborts capture, computation and pending output.
Frame RAM has synchronous reads/writes and is not reset. A fresh complete
capture precedes processing, so stale RAM contents are never emitted.

`cfg_valid/cfg_ready` atomically stores gain and offset while idle between
frames; cfg_done acknowledges on an enabled edge. Configuration has priority
over a simultaneous idle input pixel, which stays pending with s_ready low.
An accepted first frame pixel snapshots both fields. During partial capture,
computation, output and DONE, cfg_ready is low and live config values have no
effect. A held update can be accepted after completion acknowledgement.

Input is an unsigned raster with SOF exactly on pixel zero and EOL exactly on
every final-column pixel. Any marker fault aborts capture and presents stable
done_valid/done_error. Acknowledge with done_ready to start a new frame; an
incorrect SOF cannot silently restart partial capture. There are no outputs
from an aborted capture. Otherwise output is the complete raster, with x/y,
SOF/EOL/LAST, corrected pixel, raw log difference and surround. Every output
field remains stable under backpressure and CE pauses; m_valid stays asserted
through CE pauses but no transfer occurs. Input is backpressured during all
processing/output/completion phases. Successful completion has done_error zero
and holds done_valid until acknowledged. The prior error clears on next frame
start or reset.

This is serial full-frame processing: input II1 enabled cycle; first output
appears72 enabled edges after final capture; output-valid interval is73 enabled
edges when consumed immediately. It does not claim real-time video throughput.

## Verification, measured approximation and resources

```powershell
python -B cores/system/common_scaffold/image/retinex/run_tests.py
python -B cores/system/common_scaffold/image/retinex/synth.py
```

The 154-frame /4840-pixel regression covers 8/10/12-bit inputs, illumination
gradients, constants/darkness, edges, impulses, random data, thin/single-pixel/
2x2 images, low-light0/1 patterns, gain0/max, signed offsets and clipping. It
tests config snapshots and pending writes while busy, boundary arbitration,
CE/output/DONE stalls, malformed frames and recovery, and CE-low reset during
capture, surround, multiply and stalled output. Independent integer Python
calculations match every hardware raw/surround/output/metadata value.

All4096 ROM constants are independently recomputed with70-digit Decimal
logarithms and checked against a frozen file SHA256. Every simulation profile
also compares **every actual RTL ROM location** against those independent values.
Actual OpenCV5.0.0 sepFilter2D with exact binary-fraction binomial kernels checks
the unrounded surround for all4840 pixels. A separate floating-point SSR formula
uses an unrounded surround and math.log2; it is not used to change the integer
oracle to accommodate mismatches.

Measured errors over these fixtures:

| Comparison | Maximum absolute | Mean absolute |
| --- | ---: | ---: |
| Individual ROM value vs true log2, log2 units | 0.0019521772 | see full ROM audit |
| Raw vs true logs using the same rounded surround, log2 units | 0.0038533344 | 0.0008900425 |
| Raw vs floating SSR with unrounded surround, log2 units | 0.4150374993 | 0.0314921856 |
| Mapped output vs clipped floating SSR mapping, intensity units | 13.2811999769 | 1.0216684093 |

Low-light0/1 patterns expose the larger error caused by **rounding the surround
before taking its log**, even though the ROM itself is accurate. These are
measured fixture errors, not global error bounds or float-equivalence claims.

Isolated 9x7 Gowin synth/CHECK passes with no DSP:

| Bits | LUT1..4 | FF | Frame RAM | Log ROM |
| --- | ---: | ---: | --- | --- |
| 8 | 790 | 333 | 8 RAM16SDP4 | 3 SP |
| 12 | 856 | 357 | 12 RAM16SDP4 | 3 SP |

The shared full4096-entry ROM is retained in both measured configurations.
No place/route, timing closure or board acceptance is claimed. Temporary test
vectors/testbenches/binaries are automatically cleaned; compact logs persist.

## Public reference

Successfully accessed2026-10-19: [IPOL: Multiscale Retinex](https://www.ipol.im/pub/art/2014/107/).
Its description includes the single-scale log-image-minus-log-surround principle.
Only that public mathematical principle informed this independently written
fixed-binomial quantized grayscale module; no third-party source code was copied.
`reference.json` records the exact URL, access time and fetched-page SHA256.
