# Bounded Gaussian pyramidal iterative Lucas鈥揔anade flow

`pyramidal_lk_flow.v` is a self-contained dense coarse-to-fine optical-flow
engine. It builds both frame pyramids, propagates coarse flow, warps the
current frame, solves local residual normal equations and iterates entirely
in RTL. It does not wrap the existing single-scale flow module and no host
flow calculation is used by the DUT.

## Geometry and numeric contract

WIDTH/HEIGHT are arbitrary integers 8..32, including odd/non-power-of-two
sizes; at most 1024 pixels. LEVELS=2 or 3; each next dimension is ceil(n/2).
Reference/current inputs are unsigned 8-bit grayscale. WINDOW=3 or 5 and
ITERATIONS=1..4 are static parameters. This is a serial small-tile processor,
not a full-HD or real-time video-throughput claim. Flow is signed 16-bit Q4:
positive dx/dy means a reference point matches current(x+dx,y+dy).

Pyramids use the separable-equivalent 5x5 binomial kernel
`[1,4,6,4,1]^T*[1,4,6,4,1]/256`, replicate padding, round `(sum+128)>>8`,
and sample at input coordinate `(2*x,2*y)`. This fixes coordinates for odd
dimensions; geometry is not rescaled by rounded image-size ratios.

The coarsest flow starts at zero. A finer pixel samples coarse flow at
`(x/2,y/2)` using bilinear half-coordinate weights, clamps coarse sample
indices at the edge and multiplies flow amplitude by two. Interpolated Q4
values use signed arithmetic floor rounding. Each fine pixel is solved
independently given this initial estimate; neighbors in the same level are
not used as freshly computed flow seeds.

For every fixed iteration and local window sample:

1. Clamp the reference sample center to the image (replicate window border).
2. Compute unhalved reference central gradients gx=right-left, gy=down-up,
   using replicate neighbors. Reference gradients stay fixed during warps.
3. Add the pixel's current Q4 flow to that sample's coordinate. Out-of-bounds
   warp coordinates are flagged and clamped before sampling. Current image
   uses exact bilinear Q4 weights, then floors back to an 8-bit intensity.
4. Accumulate A11=sum(gx虏), A12=sum(gx*gy), A22=sum(gy虏), B1=sum(gx*It),
   B2=sum(gy*It), where It=warped_current-reference.
5. D=A11*A22-A12虏. If D<=DET_THRESHOLD (default 10000), mark texture invalid
   and leave the estimate unchanged for this iteration. Otherwise:
   `delta_x_q=trunc0(32*(A12*B2-A22*B1)/D)` and
   `delta_y_q=trunc0(32*(A12*B1-A11*B2)/D)`.

The factor 32 includes Q4 scaling and the factor two from unhalved gradients.
Clamp each update to +/-MAX_STEP_Q (default32, two pixels per iteration),
then add it. **MAX_STEP_Q is an algorithmic per-iteration update bound**,
not a numerical overflow indication. Final flow/initial propagated flow is
saturated to +/-MAX_FLOW_Q (default32767); that saturation sets overflow.
There is no early convergence stop, spatial regularization or forward/back
consistency stage. The host reference uses independent array operations and
integer dot products rather than copying the hardware state machine.

Accumulator bounds for WINDOW<=5 and 8-bit input: |gx|,|gy|,|It|<=255;
normal sums <=25*255虏=1625625. Signed32 accumulators and signed64 products,
determinants and Q4-scaled numerators cover these bounds. Wide multiply and
unsigned restoring division are shared serial 64-cycle datapaths; sign is
restored after magnitude arithmetic. Small gradient/warp/kernel products
and constant-stride addresses use explicit shift/add, avoiding DSP inference.

## Protocol, flags and errors

Paired input s_ref/s_cur advances on `ce && s_valid && s_ready`. Submit exactly
WIDTH*HEIGHT pixels, s_sof only on the first and s_eol at each row end.
Full pyramids and coarse levels are completed before finest output. Finest
output is raster ordered, m_x/m_y with m_sof/m_eol/m_last. Transfer requires
`ce && m_valid && m_ready`. Flow, flags, coordinates and valid remain stable
on CE=0 or downstream stalls. done_valid holds after the final accepted
output until `ce && done_ready`; a fresh frame then starts. Synchronous
active-high reset overrides CE, aborts all work and requires fresh capture.
RAMs are not reset; all locations used by a fresh frame are rewritten first.

m_texture_invalid, m_oob and m_overflow are sticky across iterations for
the **current layer/current pixel**. Coarse flags are **not propagated** to
finer flags; the numeric coarse estimate is still used as an initial guess,
and the finer layer independently reevaluates texture and bounds. Thus a
low-texture coarse patch does not automatically invalidate all fine results.
Window padding alone does not set OOB; the warped clamped-center coordinate
outside the image does. Once OOB occurs during any iteration it stays set,
even if later estimates move back inside. m_invalid is OR of all three flags.
These flags are conservative diagnostics, not calibrated confidence.

error_code bit0 records malformed SOF/EOL. Such a complete fixed-size input
frame is consumed, produces no flow outputs and holds DONE/error. Discard
it, acknowledge DONE and submit a fresh frame. Bit1 is reserved zero.
Unsupported static parameters cause `$fatal`; no silent fallback is used.

## References and validation

Actual open-source files were fetched over the network and their URL,
byte count, access UTC and SHA256 recorded in references.json:

- scikit-image v0.24.0 registration/_optical_flow.py and _optical_flow_utils.py
- OpenCV 4.x modules/video/src/lkpyramid.cpp

These inform coarse-to-fine warping and LK structure. OpenCV uses different
gradient processing, stopping criteria, padding and tracking windows. This
engine does not claim bit equivalence or general numerical equivalence to
OpenCV or skimage.

```powershell
python -B cores/system/common_scaffold/image/pyramidal_flow/test_pyramidal_flow.py
python -B cores/system/common_scaffold/image/pyramidal_flow/test_pyramidal_protocol.py
python -B cores/system/common_scaffold/image/pyramidal_flow/synth_pyramidal_flow.py
```

The main test checks complete flow/flag tiles against an independent integer
oracle, including 8x8/9x11/32x32, two/three levels, window3/5, textureless
images, stationary textured frames, translation, update/flow saturation,
CE/backpressure, malformed markers and multi-frame recovery. The protocol
test additionally aborts capture, Gaussian construction, multiplication,
division, warping, held output and held DONE with reset at CE=0; a complete
64-pixel stationary recovery and eleven invalid parameter cases are checked.
A separate five-frame narrow fixture verifies legal MAX_STEP_Q=128, flat
det=0 rejected at DET_THRESHOLD=0 equality, extra SOF/internal EOL errors
and subsequent recovery (192 valid output pixels).
The main entry also invokes that protocol test automatically.

A fixed independently generated 32x32 smooth random texture translated by
(4,2) pixels is compared to actual OpenCV5.0.0 PyrLK and a disabled-pyramid
single-scale version of the same integer solver. The central16x16 median
endpoint error is 0.0px for three-level flow, 4.52165px for single scale,
and 0.000652px for OpenCV. Median integer-flow/OpenCV difference is
0.001643px; 237/256 central pixels have no invalid flags. This fixture shows
coarse-to-fine recovery beyond the single-scale basin for this texture,
not a claim for every motion, occlusion or illumination change. Full RTL
output is checked against the exact integer fixture before these quality
metrics are accepted as RTL evidence.

The measured unified entry (including its original seven-phase protocol
tests) completed in 148.624 seconds; the additional narrow protocol fixture
is tested separately and is automatically included by that same entry.

Only small JSON evidence is retained; generated simulation/synthesis files
are kept in TemporaryDirectory. No board/timing signoff or side-channel claim.

Isolated Yosys synth_gowin and check-assert PASS: default16x16/three levels
uses 2802 LUT1..4, 2640 ALU, 1598 FF, 4 DPX9B and 179 MUX2_LUT5;
odd-width31x32 uses 2952 LUT1..4, 2824 ALU, 1607 FF, 6 DPX9B and
155 MUX2_LUT5. Both use 0 DSP. Even counting LUTs, ALU and wide-mux cells
together stays below 15K. This is standalone mapping, not whole-design
budget or routing/timing proof. Serialized arithmetic makes latency large;
integration must budget its actual frame latency rather than assume video rate.
