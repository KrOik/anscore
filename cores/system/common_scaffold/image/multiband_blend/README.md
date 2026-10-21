# Laplacian pyramid multiband blend

`multiband_blend.sv` takes two unsigned 8-bit grayscale images and a per-pixel unsigned 8-bit mask. It builds separate Gaussian pyramids for **both images and the mask**, forms Laplacian differences, blends each frequency band with the corresponding mask level, and reconstructs from coarse to fine. It is not a single-level weighted fusion wrapper.

## Frame and handshake contract

Runtime configuration accepts width/height **1…32** and `cfg_levels` **2 or 3** (including level zero). Maximum input frame size is 1024 pixels. Set `cfg_valid` with the configuration and wait for `cfg_ready`; success pulses `cfg_done`, invalid geometry/levels pulse `cfg_error` and retain the previous configuration. Configuration has priority over start and is accepted only while idle.

`start_valid && start_ready && ce` begins a frame with the committed configuration. Supply `s_a`, `s_b`, `s_mask` together in raster order, asserting `s_sof` only at pixel zero, `s_eol` at every row end and `s_last` only at the final pixel. Every marker is checked on every accepted sample. Hold all source fields until accepted.

All transfers require `ce && valid && ready`. Output is the original configured frame size in raster order, with `m_sof/m_eol/m_last`. Output data/markers remain stable under backpressure or CE stalls. `done_valid` is asserted after the final output pixel is accepted, and stays asserted until `ce && done_ready`. `busy` covers capture, processing and output. A new frame may start after DONE acknowledgement without reset or reconfiguration. There is no independent abort input; reset cancels a frame.

Synchronous active-low reset takes priority over CE, clears configuration and all interface validity, and cancels partially captured/processed frames. The RAM arrays do not need clearing: subsequent capture and pyramid construction overwrite all addresses that can be read for the new geometry.

Error 1 denotes malformed input markers, error 2 a signed reconstruction range failure, and error 3 an invalid internal state. Errors complete with held `done_valid`; discard the frame, acknowledge DONE and start again. A marker failure occurs before output starts, so no output pixels from that frame are emitted. Reconstruction range checking is a guard; supported 2/3-level bounded inputs fit the specified intermediates.

## Exact pyramid arithmetic

All image/mask Gaussian levels use unsigned **Q8** values, with an input pixel represented as `pixel*256`. Pyramid dimensions are `ceil(width/2)` and `ceil(height/2)` at every downsampling step. The separable binomial kernel is `[1,4,6,4,1]`; the implementation serializes its 25 outer-product taps.

`pyrDown` samples a 5×5 neighborhood centered on `(2*x,2*y)`, applies **reflect101** independently to the source coordinates and divides the weighted sum by 256. A size-one axis maps every tap to coordinate zero. Rounding is `floor((sum+128)/256)` in Q8 units.

`pyrUp` inserts zeros at odd high-resolution coordinates, applies the same 5×5 kernel with gain four and divides by 64. Only taps whose high-resolution coordinates are even contribute. The output size is the corresponding original fine-level size: either twice the coarse dimension or one less, including thin/odd frames. To match actual OpenCV `pyrUp`, negative coarse coordinates reflect101 and coarse coordinates past the right/bottom endpoint clamp to the last sample. This is the boundary behavior of the zero-inserted high-resolution convolution; applying reflect101 to the coarse array at both ends would give a different result. Rounding is `floor((sum+32)/64)` in signed Q8 units.

For non-coarsest level i, `LA_i=GA_i−pyrUp(GA_(i+1))`, likewise for B. The coarsest bands are the Gaussian images themselves. Mask weights are `GM_i/65280`, where 65280 is `255*256`. Each band computes `B + round((A−B)*GM_i/65280)`, with signed rounding to nearest and ties away from zero. Reconstruction adds the blended Laplacian band to `pyrUp` of the previously reconstructed coarse image. Signed 20-bit Q8 reconstruction RAM preserves negative/overshoot values; there is **no intermediate pixel clipping**. Final output applies `floor((value+128)/256)` and clips to 0…255.

## Implementation and verification

Four clocked-read frame memories store the three Gaussian pyramids and signed reconstruction. Fixed plane offsets reserve 1024/256/64 pixels per level. A shared filter MAC uses shifts/adds for constant kernel weights. A shared 16-cycle shift/add multiplier and 36-cycle restoring divider implement band blending; no DSP is required. The design processes a complete frame serially and makes no live-video-rate claim.

Run from the repository root:

```powershell
python -B cores/system/common_scaffold/image/multiband_blend/test_multiband.py
python -B cores/system/common_scaffold/image/multiband_blend/test_edges.py
python -B cores/system/common_scaffold/image/multiband_blend/synth.py
```

The main regression compares every actual RTL output pixel and marker against an independent integer implementation. It also runs actual OpenCV `pyrDown/pyrUp` with double-precision images and masks, using a full floating-point Laplacian blend/reconstruction reference. Twelve fixtures, including one replay without reset, cover 2/3 levels, 1×1, thin axes, odd dimensions, full 32×32 capacity, constants, identical images, mask 0/255, random data and a multiscale seam. All exact integer comparisons pass; OpenCV final pixel differences are at most one gray level. Identical/full-mask cases reproduce the corresponding input exactly. The seam fixture differs from single-level weighted fusion by up to **64 gray levels**, demonstrating different frequency-band behavior; this is not a general image-quality superiority claim.

Directed edge tests cover invalid configuration and retention, missing SOF/early EOL/early LAST, CE-gated output and DONE acceptance, and CE-low reset during partial capture, pyramid building, filter RAM read, blend multiplication/division, held output and held DONE. A complete frame succeeds after reset recovery.

Full isolated Gowin synthesis and `check -assert` pass: **1825 LUT1…4, 600 FF, 9 DPX9B, 0 DSP**, with mux cells recorded separately in `synthesis.json`. No routed timing, system integration or board validation is claimed. Temporary test/synthesis files are automatically removed; retained evidence is compact JSON and a statistics log.

OpenCV [pyramids.cpp](https://github.com/opencv/opencv/blob/4.x/modules/imgproc/src/pyramids.cpp) was fetched and reviewed for the Gaussian kernel and down/up boundary rules. The source hash and use are recorded in `reference.json`. No external implementation code was copied.
