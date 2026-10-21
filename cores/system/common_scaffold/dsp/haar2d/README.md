# Reversible integer 2D Haar lifting frame transform

`haar2d_lifting.sv` implements a real single-level forward/inverse integer Haar
transform using only addition, subtraction and arithmetic shifts. For each
signed pair (a,b), forward is d=b-a, s=a+floor(d/2); inverse is
a=s-floor(d/2), b=d+a. Arithmetic right shift implements floor for negative
odd differences. There is no floating normalization, rounding-to-zero,
division, multiplier, saturation or coefficient truncation in valid operation.

Forward processes horizontal pairs then vertical pairs; inverse reverses that
order. Each 1D pass places the ceil(N/2) low samples first and floor(N/2) detail
samples afterward. For odd N the unmatched final sample is copied unchanged
into the last low slot; inverse retrieves it and restores the last coordinate.
This rule also defines N=1 as identity along that axis, with no dropped pixels.

Input/output are row-major frames. In forward output, low rows precede detail
rows and low columns precede detail columns. Naming the **horizontal band first**:

| | low columns | high columns |
| --- | --- | --- |
| low rows | LL | HL |
| high rows | LH | HH |

The low sizes are ceil(WIDTH/2) and ceil(HEIGHT/2). All four subbands therefore
remain in one WIDTH*HEIGHT rectangular array. Inverse input uses precisely
that same layout, including odd-edge low slots.

## Signed range and checked errors

PIXEL_BITS=2..16 describes a signed spatial sample range
[-2**(PIXEL_BITS-1), 2**(PIXEL_BITS-1)-1]. Ordinary unsigned 8..16-bit grayscale
must first subtract its half-range offset (128 for 8-bit, 32768 for 16-bit)
and add it back after inverse. Both interfaces use signed COEFF_W-bit words;
COEFF_W defaults to PIXEL_BITS+3, must be at least PIXEL_BITS+2, at most 24.
The two extra bits suffice for the worst single-level 2D detail range.

Forward rejects input outside the declared spatial range. Inverse accepts
COEFF_W-bit coefficients but checks all intermediate lifting results and the
final spatial range. Pathological coefficient arrays are rejected, never
silently wrapped/saturated. Result range checks occur during computation
before output begins. Valid forward-generated arrays invert bit exactly.

error_code meanings: 1 missing/mispositioned SOF/EOL; 2 forward spatial input
range; 3 intermediate arithmetic or reconstructed spatial range. An error
aborts the frame, pulses done, returns idle and emits no result frame. Discard
any remaining beats from the aborted input and start a **fresh SOF**; the core
does not consume/discard a fixed remainder or search for synchronization.
error_code remains until reset or the next accepted first pixel. The next
frame can run without resetting. done also pulses when the final successful
output is accepted. Errors are frame failures, not permanent fail-stop.

## Handshake, RAM and latency

All transfers require **ce && valid && ready**. CE is shared with both
neighbors. Output valid/data/SOF/EOL remain stable while paused or backpressured.
SOF is exactly coordinate (0,0); EOL is the final pixel of each row. Configuration
commits cfg_inverse only between frames; cfg_valid delays a simultaneous first
pixel, but a pending mid-frame request cannot block that frame's capture.
cfg_done/done last one enabled cycle. Synchronous active-low reset overrides
CE, discards pending data, clears diagnostics and restores forward mode.

Two synchronous-read RAM arrays hold WIDTH*HEIGHT*COEFF_W bits each. The first
pass reads A/writes B, the second reads B/writes A. Memories are not reset;
each fresh frame overwrites input before arithmetic begins. Frames do not
overlap. A normal pair costs 5 enabled cycles and an odd tail costs 4.
After the final input, total arithmetic cycles are
H*(5*floor(W/2)+4*(W%2))+W*(5*floor(H/2)+4*(H%2)). First output valid appears
two enabled edges later. Subsequent output II=3 enabled cycles without stalls.
This is a bounded sequential frame core, not a line-rate or multilevel wavelet
engine. Width/height are positive static parameters.

## Evidence

```
python -B cores/system/common_scaffold/dsp/haar2d/test_haar.py
python -B cores/system/common_scaffold/dsp/haar2d/synth.py
```

Independent Python list-based lifting checks each coefficient. Six variants
(1x1/1x7/8x1/3x5/8x6/7x7, signed 8/12/16-bit spatial data) cover zero,
constant positive/negative extremes, alternating extremes, negative odd
differences and random values. Actual forward RTL outputs are captured and
fed back to inverse RTL: 36 exact roundtrips, 72 frames/1536 outputs PASS.
Tests include mode changes, valid gaps, ready stalls, CE pauses, stable output,
missing SOF/wrong EOL, input-range failures, fresh-frame recovery, invalid
inverse coefficients, computation/partial-frame reset and reset with CE low.
Four illegal parameter variants are rejected. Temporary binaries are removed
automatically; small evidence files remain.

Default 8x6/8-bit isolated Gowin synthesis (`-noalu -nodsp`) reports 691 LUT1-4,
88 MUX2_LUT5, 207 FF, 45 RAM16SDP4 and zero DSP. CHECK reports zero problems.
No P&R, clock target or board validation is claimed.
