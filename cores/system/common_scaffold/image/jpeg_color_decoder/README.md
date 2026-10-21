# Baseline color JPEG byte-stream decoder

`jpeg_color_decoder.sv` is an original synthesizable, complete JPEG byte-to-RGB decoder, built by extending this project's grayscale decoder in a separate directory. It captures a file, parses DQT/DHT/SOF0/SOS, decodes canonical Huffman entropy (including FF00 unstuffing), tracks **independent Y/Cb/Cr DC predictors**, expands AC runs/zigzag, dequantizes into signed24 coefficients, runs a shared wide serial 8x8 IDCT, schedules every MCU component block, stores native component planes, reconstructs centered chroma and emits cropped RGB raster pixels. No host-decoded coefficient/pixel input or placeholder decoder is involved.

## Supported inputs

8-bit baseline sequential interleaved **three-component YCbCr** JPEG, component IDs/order Y=1,Cb=2,Cr=3 in both SOF/SOS. Supported Y sampling is 1x1/2x1/2x2, Cb/Cr 1x1: **4:4:4, 4:2:2, 4:2:0**. All may use normal or optimized canonical Huffman tables and multiple/redefined 8-bit quantization/Huffman tables (IDs 0..3). Width and height independently support 1..MAX_SIDE and need not be MCU/block multiples. MCU edge padding is decoded but cropped from native planes and final raster. Default MAX_SIDE=32 and MAX_BYTES=8192; the synthesis result applies to this profile. MAX_SIDE is explicitly bounded to 1..256, but larger profiles require new resource/timing checks.

APP/COM segments are skipped by declared length. Adobe APP14 with signature `Adobe` is accepted only when transform=1 (YCbCr); transform0 RGB and transform2 YCCK are rejected, and truncated Adobe metadata fails. Non-Adobe APP14 remains opaque metadata. DRI is accepted only at exact length4 and interval0 (no restart). Positive restart intervals/restart markers, progressive/extended/arithmetic/hierarchical JPEG, grayscale, RGB-coded component IDs, CMYK, other sampling ratios, separate/noninterleaved scans, multiple scans and externally supplied abbreviated tables are explicitly unsupported. EXIF orientation is metadata, not a requested raster transform. APP color profiles do not change the fixed JPEG YCbCr conversion.

Every file must contain its own referenced tables, valid nonzero quantization values, legal canonical trees without all-ones words, valid category/run sequences, all-ones final entropy padding, and an exact terminal EOI. Trailing bytes are rejected. Incomplete/empty table segments and malformed header fields terminate explicitly. Input capture is finite; bytes beyond MAX_BYTES fail instead of wrapping memory.

## Reconstruction and RGB numerical behavior

The source chroma samples are centered at `(H*i+(H-1)/2,V*j+(V-1)/2)`, where H/V are Y sampling factors. Normal-width chroma uses a true centered triangle/bilinear filter with independently replicated borders and **one final** round-half-up; there is no premature rounding between vertical and horizontal interpolation. Thus horizontal 2x even/odd taps are `(C[k-1]+3*C[k])/4` and `(3*C[k]+C[k+1])/4`; 2x2 uses the corresponding 9/3/3/1 weights over16. Four synchronous native-plane reads feed each output pixel.

For subsampled chroma planes of width <=2, interpolation falls back to box/nearest reconstruction in both axes, matching libjpeg's actual `downsampled_width>2` fancy-selection condition. This matters for widths1..4: applying bilinear unconditionally is a different valid reconstruction but can differ from Pillow by tens of gray levels. `test_narrow.py` explicitly covers widths1/2/3 for every supported sampling ratio, rather than loosening an error threshold to hide this distinction. A 4:4:4 image always uses its native samples directly.

Our normal-width filter rounds ties up uniformly. Libjpeg fancy alternates rounding bias between positions; at ties this can change reconstructed chroma by1. This implementation deliberately shares the same spatial phase/kernel, not every software rounding detail. RGB uses JPEG full-range conversion:

```
R = clip(Y + round(91881*(Cr-128)/65536))
G = clip(Y + round((-22554*(Cb-128)-46802*(Cr-128))/65536))
B = clip(Y + round(116130*(Cb-128)/65536))
```

All channels are clipped to0..255; no studio-range offset is applied. Signed32 color intermediates safely hold the <=128*116130 magnitude. Independent `oracle.py` parses the actual compressed bytes, decodes Huffman/DC/AC itself, applies a NumPy **double orthonormal IDCT**, reconstructs by direct spatial-coordinate interpolation (with the explicit narrow fallback), and converts using real-valued JPEG color coefficients. It does not generate expected pixels by mirroring RTL states or by feeding host coefficients.

Pillow-generated normal/optimized fixtures at qualities20..100, including random/gradient/solid/tiny, odd geometry and32x32 multi-MCU frames, compare to both this oracle and actual Pillow/libjpeg RGB output. Evidence records maximum, MAE and95th-percentile errors. Ordinary cases observed <=3/channel; test limits are5 against the independent real-arithmetic oracle and6 against Pillow, allowing combined IDCT/interpolation/color rounding without a broad image-quality tolerance. These bounded fixtures are not universal bit-exact or perceptual-quality claims.

## Wide IDCT bounds

DC difference category<=11, AC magnitude category<=10; DC predictors outside[-2048,2047] explicitly fail. DC category11 describes a difference, not proof of physical8-bit-image validity. Quantization is exact in signed24 with conservative coefficient bound A=2048*255=522240. The serial orthonormal matrix uses signed28 Q26 constants, signed24 first-pass samples, signed56 product/accumulator and28 shift/add steps per multiply. No signed16 truncation occurs.

Let delta=2^-27 be matrix rounding error. Each rounded matrix row has absolute sum<=sqrt(8)+8*delta. First-pass rounded values are bounded by A*(sqrt(8)+8*delta)+0.5 <1,477,120 <2^21, safely in signed24. Second-pass unshifted sums are <1,477,120*(sqrt(8)+8*delta)*2^26 <2^49, safely in signed56. Versus ideal real IDCT, matrix error is<64*A*(delta+delta^2)<0.25 and first-pass rounding contributes<1.415 gray levels. Final rounded native samples therefore differ by at most2 integers within this explicit domain; clipping does not enlarge error.

`test_numeric_limits.py` supplies six **entropy-category stress** streams covering all sampling ratios with dequantized magnitudes up to521985. They agree exactly with the independent ideal-IDCT/reconstruction/RGB oracle in the recorded fixtures. They deliberately exceed normal reconstructed8-bit sample dynamic range and differ from Pillow by up to255, which is recorded, not suppressed. These cases prove wide arithmetic behavior; they do not establish that arbitrary such coefficient combinations represent physical images or universal libjpeg equivalence.

## Interface, errors and recovery

Control is `clk/rst_n/ce`, `start_valid/start_ready`, `abort`. Input `s_data[7:0]/s_valid/s_last/s_ready` carries one whole compressed file, LAST on its final byte. Output `m_data[23:0]` is **{R,G,B}**, `m_valid/m_ready/m_sof/m_eol/m_last` is the width*height raster. `width/height` are decoded metadata. `done_valid/done_ready/done_error/error_code/busy` hold terminal status. All transfers require enabled valid/ready at a rising edge. Ready is suppressed during reset, CE=0 and abort. Output tokens and held DONE are stable under CE pauses/backpressure. Acknowledging DONE permits another file without reset; every START invalidates previous tables/predictors.

Reset is synchronous active-low and overrides CE. Abort immediately suppresses output and is latched into error on an enabled edge; hold it through that edge. Errors before replay emit no pixels. Replay abort invalidates the whole frame, including previously emitted pixels. Late abort does not alter held DONE. Metadata and markers are relevant only to their valid transaction. Capture cannot detect a source that never sends LAST; use abort/reset in that case. A truncated LAST-terminated file does fail bounded fetch. No input watchdog is claimed.

Error codes:80 invalid static profile;81 capture overflow;82 truncated file;83 SOI;84 marker prefix;85 unsupported process/marker/restart/Adobe transform;86 segment length/truncated Adobe metadata;87 SOF/sampling/component fields;88 SOS/order;89 quant table;8A Huffman table;8B missing referenced table;8C entropy marker/stuffing;8D undecodable code;8E DC category;8F AC category/run;90 predictor domain;91 fill/EOI/trailer;93 abort;94 internal state.

This implementation is serialized and whole-frame buffered. It makes no one-pixel-per-clock, camera-rate, post-route timing, board acceptance or broad JPEG-compliance claim. Plane RAM stores are allocated at the configured maximum profile; actual native chroma geometry controls valid addresses.

## Reproduce and evidence

From repository root:

```powershell
python -B cores/system/common_scaffold/image/jpeg_color_decoder/run_tests.py
python -B cores/system/common_scaffold/image/jpeg_color_decoder/test_narrow.py
python -B cores/system/common_scaffold/image/jpeg_color_decoder/test_protocol.py
python -B cores/system/common_scaffold/image/jpeg_color_decoder/test_numeric_limits.py
python -B cores/system/common_scaffold/image/jpeg_color_decoder/synth.py
```

The required `idct_coeff.hex` is reproduced by `generate_coefficients.py`. JSON evidence freezes RTL/ROM SHA256; synthesis conservatively includes4 LUT-class cells per RAM16SDP4. Temporary compilation/synthesis directories clean automatically. Fault fixtures run twice then decode a healthy independent JPEG without reset. Protocol tests abort seven internal phases, reset during arithmetic with CE=0, and then decode healthy frames. External end-to-end encoder wiring is integrated by the parent task, separate from standalone evidence.

`references.json` records T.81/libjpeg references retrieved/studied earlier in this session plus the newly downloaded `jdsample.c` hash. T.81 AnnexB/C/F guided syntax, canonical coding and reconstruction; libjpeg source confirmed centered triangle phase, alternating rounding and narrow fallback. Existing project 422/420 reconstruction modules were read as mathematical references. No third-party source code was copied into RTL. Downloaded reference files and task-only development scripts are removed after inspection.
