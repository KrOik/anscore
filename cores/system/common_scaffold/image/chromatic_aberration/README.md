# RGB lateral chromatic aberration correction

This module captures a complete RGB frame and corrects red and blue independently using hardware-generated radial inverse maps and bilinear resampling. Green is copied exactly at its original pixel position. It is a working pixel-processing core, rather than a map-only wrapper. One actual lens mapper and one actual production frame sampler are shared serially: capture RGB, map/sample the entire red plane into a red-result RAM, then map/sample blue while publishing RGB with the stored corrected red and unmodified green.

## Interface and configuration

`chromatic_aberration_frame` parameters are WIDTH, HEIGHT, BITS. BITS accepts 8..12, each dimension 1..4096, with WIDTH*HEIGHT <=65536. Odd sizes and thin 1xN/Nx1/1x1 tiles work. Storage is N*(3*BITS+BITS+2) bits: RGB source plus corrected red and two red flags. No memory contents need reset because each frame overwrites all source and red entries before reading them.

RGB words are `{R,G,B}`, with BITS bits each. `cfg_red` and `cfg_blue` each contain nine signed32 fields, from low to high: fx, fy, cx, cy, invfx, invfy, k1, k2, k3. Focal lengths, centers and coefficients are Q16.16; inverse focal lengths are Q2.30. `cfg_border={R,G,B}` supplies border values (green border is unused because green stays in place).

Each color computes x=(u-cx)*invfx, y=(v-cy)*invfy, r²=x²+y², radial=1+k1*r²+k2*r⁴+k3*r⁶, source=(fx*x*radial+cx,fy*y*radial+cy). Radial is Horner-evaluated. R and B may have different centers, focal lengths and coefficients. No tangential model, longitudinal color correction, sensor calibration estimator or optical quality claim is included. The caller supplies calibration; green defines the output raster.

Focal lengths must be 1..8192, centers ±8192 and inverse focal lengths positive <=1. Focal and inverse fields are independent; normally configure reciprocal pairs. Coefficients accept all signed32 values. Fixed-point operations saturate signed32 and round nearest with ties away from zero at every operation, matching the documented lens mapper arithmetic. The shared full Brown-Conrady microcode evaluates tangential geometry with p1=p2=0 as well; overflow from those intermediate stages also conservatively flags the pixel. Coordinates are classified for OOB or overflow before Q16-to-Q8 fractional truncation. Either condition substitutes that color's configured border with no source memory access. In-range coordinates use four-read bilinear interpolation with edge replication and one final half-up rounding. The weighted average remains within the source channel range, so no additional pixel saturation is needed.

`m_oob[0]` and `m_overflow[0]` describe red; bit1 describes blue. OOB checks final saturated coordinates independently of overflow. Green always preserves the captured value. Error flags describe each output pixel, not configuration failure.

## Transactions

Synchronous active-low reset overrides CE, flushes control and configuration, and invalidates output/done. No default calibration exists. Atomically configure both planes with cfg_valid/cfg_ready; cfg_done pulses on acceptance and cfg_error/code2 reports an invalid bundle while retaining the previous calibration. Config takes priority over simultaneous start. Inputs presented while busy must hold valid/data until ready and cannot alter the active frame. A valid configuration clears error_code.

After start_valid/start_ready, supply exactly N raster-order pixels on s_valid/s_ready with s_sof on pixel0 and s_eol on each row's last pixel. An unconfigured start reports error_code1 and does not capture. Bad input metadata sets done_error but still captures N samples and produces deterministic output; it never silently restarts the frame. done_error resets at a new accepted configured start. s_ready is low throughout processing.

m_valid/m_ready transfers RGB and sof/eol/last. Output and metadata hold during backpressure. done_valid holds until done_ready. All transfers, including memory and output, require CE=1; ready inputs/outputs alone must not be interpreted as consumption when CE=0. Reset during capture, arithmetic or stalled output discards the frame; the next frame needs configuration again. The serialized design prioritizes resource size and requires about two map passes at ~560 enabled clocks per pixel, plus sampling/capture/output overhead; it is not a pixel-per-clock video core.

## Dependencies and evidence

`sources.f` explicitly lists the existing `lens_distortion_map.sv` and production `img_geo_frame_sampler.v` dependencies. Both are used as actual RTL, unchanged. Run from repository root:

```
python -B cores/system/common_scaffold/image/chromatic_aberration/run_tests.py
python -B cores/system/common_scaffold/image/chromatic_aberration/run_synthesis.py
```

Independent integer oracle passes 60 frames /1356 RGB pixels at 1x1 B8,1x7 B10,7x1 B12,7x5 B8,9x7 B12. Tests include different per-plane calibrations, extreme coefficients, explicit border/overflow bits, exact green preservation, malformed framing, invalid calibration retention, pending configuration during a frame, CE stalls, input/output stalls, configuration/start priority and reset during capture/arithmetic/stalled output. Six invalid geometry/bit-depth parameter cases are rejected. Actual OpenCV inverse-map plus remap cross-check compares in-domain channel pixels: maximum differences are 0/3/10/2/18 LSB respectively. OpenCV INTER_LINEAR uses 1/32 coordinate interpolation tables; RTL uses Q8 fractions, so those comparisons are bounded numerical differences, not bit-exact claims. test_evidence.json contains counts and RMSE. All emitted RGB pixels are independently exact against the integer oracle, including the border cases excluded from OpenCV comparisons.

Full-hierarchy 9x7 synthesis including actual mapper/sampler passes Gowin check with zero problems: B8 5471 LUT1..4 +401 MUX2_LUT5,2104 FF,36 RAM16SDP4,0 DSP; B12 6038 LUT1..4 +393 MUX2_LUT5,2220 FF,52 RAM16SDP4,0 DSP. This is small-tile synthesis only: larger frame RAM capacity and placement depend on the target FPGA. No routing, frequency, hold or board signoff is claimed. Temporary simulation and synthesis artifacts are automatically removed; compact evidence remains. synthesis_failure.log preserves an initial Yosys direct-parameterization failure; the reproducible wrapper-based synthesis avoids that tool assertion without editing dependencies.

Reference URLs and successful fetch hashes/times are in reference.json. Lensfun documents independently calibrated red/blue transverse chromatic aberration, and OpenCV provides the remap/interpolation implementation reference. No source code from either reference was copied.
