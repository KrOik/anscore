# Grayscale block-pixel JPEG entropy encoder

`jpeg_grayscale_scan.sv` connects the production extension DCT, quantizer,
coefficient symbolizer, default Huffman lookup and multi-block entropy scan
controller. Its input is unsigned 8-bit grayscale pixels in 8x8 block order.
The encoder performs signed level shift by 128 and emits a baseline entropy
scan, including raw restart markers. File headers and raster/block rearrangement
are separate reusable cores, not embedded in this module.

Write all 64 positive 8-bit quantization entries using table_valid/ready in
natural matrix order; then commit with cfg_valid/ready and wait for cfg_done.
cfg_error reports a rejected/incomplete table and retains the old valid table.
Configure only between scans. Start uses cfg_total_blocks and a restart interval
in blocks (for grayscale this equals MCU count). Zero blocks is explicitly
rejected by the scan controller. Runtime widths and heights belong to the
separate header and raster modules and must agree with the selected block count.

For each accepted pixel, s_block_first marks index 0, s_block_last marks index
63, and s_frame_last marks only the last pixel of the final padded block. Supply
exactly 64 pixels per block. The raster core replicates right/bottom edge pixels
for nonmultiples of eight. Ordinary block boundaries keep entropy bits continuous.
Restart boundaries drain and pad entropy, emit unstuffed RST0..7 and acknowledge
a predictor-reset event before the next block is admitted. Blocks are deliberately
serialized through entropy acceptance so an upstream DC predictor cannot get
ahead of that reset. The normal block datapaths still apply their own ready/valid
backpressure. This is a bounded-resource serial implementation, not a video-rate
throughput claim.

The transfer condition is **ce && valid && ready**; the connected cores share CE.
Reset is synchronous active-low for this wrapper and the transform/control cores;
it also clears the internal bit packer's pending byte. done_valid is held until
done_ready. Check error_code before accepting a result; partially emitted data
cannot be rolled back. Local error codes are 81 malformed block markers, 82 DCT
saturation, 83 quantizer saturation, 84 symbol error, 85 Huffman error and 86
abort. Local faults stop further input until global reset and table reload.
Lower codes are scan-controller status codes documented in its directory.

From the repository root:

```powershell
python -B cores/system/common_scaffold/integration/test_jpeg_frame.py
python -B cores/system/common_scaffold/dsp/jpeg_grayscale/test_errors.py
python -B cores/system/common_scaffold/dsp/jpeg_grayscale/synth.py
```

The frame regression instantiates the actual raster rearranger, this encoder
and the RTL header emitter. It compares entropy bytes with an independent
fixed-point/canonical-code oracle and decodes the complete RTL-generated JPEG
using Pillow. The 8x8, 16x16, 13x9 and 1x1 fixtures use restart intervals 0, 1,
2 and 1 with random CE/source/output stalls and a constant quantization table
of 8. Maximum decoded pixel errors are respectively 8, 8, 6 and 0. These are
lossy grayscale baseline fixtures; color, progressive JPEG and continuous frame
throughput are outside this interface. Generated tiny JPEGs are retained as
reviewable evidence; temporary vectors and simulation executables are removed.

No P&R, physical board or camera/display acceptance is claimed.

Integrated-core Gowin synthesis (`-noalu -nodsp`) passes `check -assert`:
4517 LUT1..4, 426 MUX2_LUT5, 2 MUX2_LUT6, 826 FF and 80 RAM16SDP4,
zero DSP. This includes the transform/entropy dependencies, and excludes the
separate header emitter and image-size-dependent raster frame RAM. Source-bound
evidence is in `evidence/jpeg_grayscale_synth_20261018T182048Z_00edbffa/`.
