# Brown–Conrady inverse coordinate map

`lens_distortion_map.sv` generates row-major rectified output `(u,v)` to distorted source `(sx,sy)` coordinates. This is the mathematical map generator; it does not store or interpolate image pixels. Connect source Q16.16 coordinates to the existing frame sampler by retaining the integer/sign portion, truncating the low 8 fractional bits for Q8, and applying the OOB/overflow border policy.

The equations use normalized x=(u-cx)*invfx and y=(v-cy)*invfy; radial=1+k1*r²+k2*r⁴+k3*r⁶; xd=x*radial+2*p1*x*y+p2*(r²+2*x²), yd=y*radial+p1*(r²+2*y²)+2*p2*x*y; source=(fx*xd+cx,fy*yd+cy). Radial is evaluated in Horner order. No rotation matrix or separate destination center is implemented.

## Arithmetic and limits

fx/fy/cx/cy and coefficients are signed Q16.16; invfx/invfy are positive signed Q2.30. fx/fy accept 1..8192, centers ±8192, inverse focal (0,1], and coefficients accept all signed 32-bit values. Inverses and focal lengths are independent parameters; the caller normally configures reciprocal pairs. All intermediate arithmetic is signed Q16.16, rounds nearest with ties away from zero, and saturates on overflow. Overflow is sticky for the current pixel only; the saturated coordinate is still emitted. OOB is independently computed from final coordinates with exact last source pixel accepted.

Geometry parameters accept 1..4096 per dimension. One serial shift/add multiplier is shared; 16 multiplications require approximately 560 enabled clock cycles per pixel. This prioritizes small resource usage and is not a full-rate video pipeline.

## Transaction interface

There is no reset-default calibration. An unconfigured start is accepted and reports error code 1 without a frame. A config bundle is accepted only while idle, atomically; invalid config pulses cfg_error/code 2 and retains the previous calibration. Config wins over simultaneous start. Config must remain valid until cfg_ready, including during active frames. Configuration cannot change mid-frame. A successful configuration clears error_code; runtime arithmetic overflow is reported per pixel rather than through configuration errors.

Output remains stable under backpressure and disabled CE. `done_valid` holds until `done_ready` with CE enabled; a new frame requires returning idle. Reset is synchronous active-low and overrides CE. Ready is gated by reset and CE. All handshakes and consumption require CE=1; no input/output may be consumed on CE=0.

## Evidence

Run `python -B cores/system/common_scaffold/image/lens_distortion/run_tests.py` from repository root. Independent saturating Python oracle: 49 frames / 1715 coordinates pass, including all terms, negative/OOB coordinates, extreme signed coefficients and saturation, CE stalls, output and done backpressure, invalid-config retention, config/start priority, and reset during arithmetic. Actual OpenCV `initUndistortRectifyMap` comparison: 46 frames / 3220 coordinate components, maximum absolute error 0.000451446 pixels, RMSE 0.000117194 pixels. These differences reflect staged fixed-point rounding.

Isolated `synth_gowin -noalu -nodsp; check` passes with 0 reported problems: 3345 LUT1..4, 298 MUX2_LUT5, 1053 FF, 0 DSP. This is synthesis only, without routing or board frequency/signoff. Full standalone top I/O count is not a board pin assignment. Temporary simulations/netlists are automatically removed; only compact JSON evidence is retained.

`reference.json` records successful access to the OpenCV implementation for formula/direction review. No implementation source was copied. Board validation and sampling integration remain pending and must not be inferred from these numerical tests.
