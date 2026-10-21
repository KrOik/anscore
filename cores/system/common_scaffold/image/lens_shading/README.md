# Four-plane Bayer mesh lens-shading correction

`lens_shading.sv` corrects RAW Bayer pixels using four independent host-loaded gain meshes, exact rational bilinear interpolation and one final RAW rounding/saturation. It is a real per-pixel mesh correction engine, not a piecewise-constant gain selector. The existing repository Bayer ABI is preserved: **0=RGGB,1=GRBG,2=GBRG,3=BGGR**.

## Plane and geometry contract

Map channels are0=R,1=Gr (green on a red row),2=Gb (green on a blue row),3=B. Flattened cfg_index is `channel*GRID_WIDTH*GRID_HEIGHT + mesh_y*GRID_WIDTH + mesh_x`. Each channel has its own entire mesh; the two green channels can have different gains. The top-left RAW coordinate is(0,0), with no crop offset beyond the selected Bayer pattern.

Mesh vertex gx is exactly at full-frame coordinate `gx*(WIDTH-1)/(GRID_WIDTH-1)`, and similarly for y. For pixel(x,y), the mesh coordinate is `u=x*(GRID_WIDTH-1)/(WIDTH-1)`, `v=y*(GRID_HEIGHT-1)/(HEIGHT-1)`. The engine chooses the cell by floor and evaluates all four vertex gains with exact fractional weights. The last image column/row selects the final mesh endpoint without an out-of-range cell. Non-divisible grid spacing is not rounded to integer cell widths. If WIDTH=1, that axis uses mesh coordinate0 (the first mesh column); HEIGHT=1 analogously uses the first row. This explicit thin-image rule avoids division by zero and does not silently average the mesh.

GAIN_BITS unsigned entries represent gain/2^GAIN_FRAC (default unsignedQ4.12,16 bits). RAW is unsigned8/10/12 bits. Let DX=max(WIDTH-1,1), DY=max(HEIGHT-1,1), and rx/ry be the exact cell-phase numerators over DX/DY. The weighted gain numerator is

`S = g00*(DX-rx)*(DY-ry) + g10*rx*(DY-ry) + g01*(DX-rx)*ry + g11*rx*ry`.

Output is nearest-half-up `RAW*S/(DX*DY*2^GAIN_FRAC)`, then clipped to[0,2^BITS-1]. `m_saturated` means the rounded value exceeded that limit. There is **no intermediate gain rounding**, so an exact rational mesh is preserved until the final RAW result. Gain0 outputs0, unity gain preserves the original RAW exactly, and no black-level subtraction or demosaic is folded into this core.

Allowed parameters: WIDTH/HEIGHT1..4096 with source pixels<=65536, BITS8/10/12, GRID_WIDTH/HEIGHT2..9, GAIN_BITS2..24, GAIN_FRAC0..20. Fraction counts declare scaling and need not be smaller than storage width. A mesh larger than the image is legal and uses the same rational-coordinate rule.

## Double-buffer configuration and frame lifecycle

All transfers require rst_n && ce && valid && ready. Write each distinct cfg_index through cfg_valid/cfg_ready and cfg_gain, then commit through cfg_commit_valid/cfg_commit_ready. A bitmap requires every one of the4*GW*GH entries to have been written since the previous bank swap. Duplicate writes do not satisfy missing entries. Out-of-range index or incomplete commit sets cfg_error and preserves the old active map. Any later valid map write or successful commit clears cfg_error. A bad index does not modify memory or completeness bits.

One active map is immutable throughout an entire frame. Configuration writes always target the other bank and are permitted during pixel processing/output. A full commit accepted in idle activates immediately; a full commit accepted while busy sets cfg_pending and queues the complete inactive map. Pending commits lock both configuration ready signals to prevent later writes from changing the committed next map. After the current frame is acknowledged and the FSM returns to idle, the banks swap atomically, completeness clears, and cfg_pending clears. The former active map becomes the next loading bank, and all entries must be written again before another commit. No pixel can use a mixture of maps.

cfg_valid and cfg_commit_valid are mutually exclusive producer actions: asserting both yields neither ready. start_valid/start_ready is accepted only in idle with a committed active map and no pending/config transaction; it snapshots cfg_pattern for the whole frame. Changing cfg_pattern later cannot alter that frame. Finish map commit before requesting start. There is no default/unity map after reset.

The source streams exactly WIDTH*HEIGHT RAW pixels via s_data/s_valid/s_ready, with SOF only on the first pixel, EOL on each row end and LAST only on the final pixel. Corrected outputs preserve raster position with m_sof/eol/last. Output data, saturation and markers stay stable until ce && m_ready. Start/source/config ready are gated by CE; m_valid and done_valid remain asserted during CE pause. Done holds until ce && done_ready.

A source-marker mismatch terminates with done_error/error_code1. Earlier output pixels from that frame may already have been consumed; clients must reject the frame on error. Acknowledge completion then start a whole new frame, retaining the active map (or applying a queued complete map at idle). Error2 is an illegal-FSM recovery diagnostic. Configuration diagnostics are independent from frame protocol diagnostics. There is no timeout for absent source data or output backpressure.

Synchronous active-low reset overrides CE, aborts active work/output and clears configured/pending/completeness/diagnostics. The map memories are not reset, but no stale map is usable: a fresh complete load/commit is required. Frame counters and Bayer phase restart from(0,0).

## Architecture, resource and evidence

The hardware has one double-bank gain memory with an inactive-bank write port and registered active-bank read port. A single unsigned64-by32 shift/add engine computes the four integer weights, four weighted vertex gains and RAW product. A64-cycle restoring division computes the final exact quotient/remainder. The four weights sum exactly to DX*DY. Maximum weight<2^24, weighted gain<2^48, RAW numerator<2^60 and denominator<2^44, safely within64-bit datapath/65-bit remainder. No generic multiplier/divider or DSP arithmetic is instantiated. Constant geometry index arithmetic is synthesized from static dimensions.

A point produces valid output372 enabled clock edges after acceptance; downstream stalls extend its lifetime. This is serialized one-point-at-a-time processing, not video-rate II1. Default33x25/BITS12/3x3 mesh/GAIN16.12 isolated Gowin synthesis uses2122 conservative LUT-class/0DSP/0BRAM (20 RAM16SDP4 counted as80 LUT equivalents). Alternate35x27/BITS10/5x5 uses3058 LUT-class/0DSP/1 DPX9B, conservatively2 units of9Kb. Totals include ALU/MUX/LUTRAM; raw primitives and current RTL SHA256 are retained. Legal larger configurations require their own resource assessment. No PNR, timing or board acceptance is claimed.

```
python -B cores/system/common_scaffold/image/lens_shading/run_tests.py
python -B cores/system/common_scaffold/image/lens_shading/test_protocol.py
python -B cores/system/common_scaffold/image/lens_shading/test_numeric_limits.py
python -B cores/system/common_scaffold/image/lens_shading/synth_check.py
python -B cores/system/common_scaffold/image/lens_shading/freeze.py
```

16 numerical frames/3771 RAW pixels compare every output/status/marker and every intermediate weighted-gain numerator against independent Python Fraction geometry/interpolation. Tests cover all four Bayer patterns with distinct unequal-channel maps, spatially nonlinear random maps,8/10/12-bit unity,zero/max24-bit gains,maximum gain-fraction20, saturation, half-up ties, thin1x1/1x13/13x1,non-divisible grid spacing and9x9 mesh over3x2 pixels. Randomized CE/output stalls and busy configuration mutations are enabled.

Protocol tests check3 configuration errors,4 marker errors including a partial emitted frame,4 CE-disabled resets at input/multiply/divide/output,9 complete healthy/recovery frames, inactive loading during active processing, pending commit lock and exact next-frame bank switching.14 invalid parameter configurations and49062 exact integer weight-partition checks cover arithmetic/parameter limits. All test/synthesis result JSONs bind current RTL SHA256.

Mature ISP source references are in references.json. The Raspberry Pi libcamera ALSC spatial `resampleCalTable` implementation was downloaded and inspected: it uses floor/phase neighboring samples and two-dimensional linear gain-table interpolation. Its sensor-crop geometry differs from this core's explicitly specified full-frame endpoint mesh, so no bit-exact libcamera equivalence is claimed. An inspected Infinite-ISP LSC source currently returns the unmodified image; it is explicitly excluded as an algorithm reference rather than treated as a working example. No external code was copied.

Temporary simulations, synthesis and source downloads use TemporaryDirectory and are cleaned automatically. Only small reproducible source/evidence files remain.
