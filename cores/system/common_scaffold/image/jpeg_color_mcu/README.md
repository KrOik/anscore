# RGB8 to color JPEG MCU sample blocks

`jpeg_color_mcu.v` converts actual RGB raster data to full-range Y/Cb/Cr
sample blocks in JPEG MCU order. Both 4:4:4 and 4:2:0 are supported per-frame
through cfg_sampling_420 sampled at START. This stage does not perform DCT,
quantization, entropy coding or JPEG marker generation; its sample stream
feeds those encoder stages.

WIDTH and HEIGHT are positive integers <=65536, with WIDTH*HEIGHT<=65536.
Odd dimensions and one-pixel-wide/high images are supported. The complete
RGB frame is stored in synchronous RAM before sample output. Default16x16
is small; supported maximum capacity is a separate, much larger RAM cost.

## Exact color and sampling contract

Input s_rgb[23:0] is `{R[7:0],G[7:0],B[7:0]}`. Each channel conversion uses
these signed integer expressions, arithmetic shift and clamp to 0..255:

```
Y  = ( 19595*R + 38470*G +  7471*B +   32768) >> 16
Cb = (-11059*R - 21709*G + 32768*B + 8421376) >> 16
Cr = ( 32768*R - 27439*G -  5329*B + 8421376) >> 16
```

Constants implement BT.601 full-range conversion with the specified rounding.
This is not studio/video limited-range YCbCr. Intermediate signed32 values
cover all 8-bit RGB extrema. Pure blue Cb and pure red Cr can round to256;
per-pixel clamp occurs before any subsampling average.

For 4:4:4, one MCU covers 8x8 source pixels and emits three 8x8 blocks:
Y, Cb, Cr. For 4:2:0, one MCU covers16x16 and emits six blocks:
Y0(top-left), Y1(top-right), Y2(bottom-left), Y3(bottom-right), Cb, Cr.
MCUs are raster ordered, and every block is emitted in 8x8 raster sample
order. Component encoding is 0=Y,1=Cb,2=Cr. Values are unsigned8, without
subtracting128; level shift belongs to the downstream DCT interface.

The 4:2:0 Cb/Cr sample at MCU-local chroma(x,y) converts the four original
RGB pixels at `(2*x+dx,2*y+dy)` independently, clamps each converted channel,
then returns `(a+b+c+d+2)>>2`. This is half-up averaging. It deliberately
does not alternate rounding bias as some optimized JPEG implementations do.
Every source coordinate outside the image is first clamped to the nearest
valid edge pixel, including incomplete luma blocks, chroma2x2 groups and
fully padded blocks within the final MCU. Thus no partial block is emitted.

## Handshakes and recovery

1. Accept START on `ce && start_valid && start_ready`. cfg_sampling_420 is
   snapshotted here and can change afterward without affecting the frame.
2. Supply exactly WIDTH*HEIGHT paired RGB/marker transfers using
   `ce && s_valid && s_ready`. s_sof must mark only the first accepted pixel;
   s_eol must mark every source row end. Input is accepted only after START.
3. Consume outputs on `ce && m_valid && m_ready`. All sample data, component,
   flags and m_mcu_index remain stable when CE=0 or the consumer stalls.
4. done_valid is held until `ce && done_ready`. Only then can the next START
   be accepted. Holding start_valid while busy does not start another frame.

m_block_first/last mark sample0/63 of every block. m_mcu_last marks the
last sample of the final Cr block of each MCU. m_frame_last marks that same
sample only on the final MCU. These markers are qualified by m_valid.
m_mcu_index is zero-based32-bit. In particular, m_mcu_last is not asserted
on every sample of an MCU; it is a terminal-sample pulse held with its token.

error_code bit0 records any SOF/EOL sequence error. The full fixed-size input
frame is consumed, no sample tokens are emitted, and DONE/error are held.
Discard that frame, acknowledge DONE, issue a fresh START and resend a full
frame. Bits3:1 are reserved zero. There is no timeout or hidden resynchronizing
on a stray SOF. Unsupported static geometry causes `$fatal`.

rst_n is synchronous active-low and overrides CE. Reset aborts any partial
capture/output and returns to idle. RAM is not reset; a fresh START and full
capture rewrite all locations before output reads. done_valid, busy and
ready/valid behavior therefore do not depend on stale frame contents.

## Architecture and references

One synchronous 24-bit RGB frame RAM supplies the mapper. Exact constant
products are explicit shift/add; no runtime multiplier or DSP is needed.
4:4:4/luma output uses ADDRESS, READ, CONVERT, held OUTPUT; 4:2:0 chroma
uses four synchronous source reads and a10-bit sum before held output.
Source row strides and MCU origins also use shifts/additions.

Actual libjpeg-turbo source was fetched and inspected for color conversion,
downsampling, edge expansion and MCU block organization:

- https://raw.githubusercontent.com/libjpeg-turbo/libjpeg-turbo/main/src/jccolor.c
- https://raw.githubusercontent.com/libjpeg-turbo/libjpeg-turbo/main/src/jcsample.c
- https://raw.githubusercontent.com/libjpeg-turbo/libjpeg-turbo/main/src/jcprepct.c
- https://raw.githubusercontent.com/libjpeg-turbo/libjpeg-turbo/main/src/jccoefct.c

references.json records exact fetched SHA256, byte count and access UTC.
The requested formulas and deterministic half-up averaging are this core's
contract; no claim is made that every libjpeg SIMD/downsampling rounding path
is byte identical.

## Verification and resources

```powershell
python -B cores/system/common_scaffold/image/jpeg_color_mcu/test_jpeg_color_mcu.py
python -B cores/system/common_scaffold/image/jpeg_color_mcu/test_jpeg_color_protocol.py
python -B cores/system/common_scaffold/image/jpeg_color_mcu/synth_jpeg_color_mcu.py
```

The integer oracle uses NumPy64 direct matrix formulas and an independent
MCU/block generator, not the DUT's address state machine. Tests cover both
modes and changing modes across frames, immediate config changes after START,
black/white/primary/complement colors, random images, 1x1,1x17,17x1,7x9,
16x16,17x19,31x33 and maximum-capacity65536x1. Every actual emitted sample,
component, MCU index and marker is compared, including replicated edges.
Output and DONE valid/payload/error holding are checked under CE and
backpressure. Color conversion is independently compared with actual
OpenCV RGB→YCrCb (reordered to YCbCr) and Pillow RGB→YCbCr on16384 pixels;
per-channel differences are bounded to1LSB rather than pretending the
libraries share exactly the same rounding.
Final unified run PASS:55 frames,75748 accepted RGB pixels and1613568 exact
MCU sample tokens. It completed in76.582 seconds; maximum-capacity fixture
alone took61.928 seconds. Actual OpenCV5.0.0 and Pillow12.3.0 comparisons
both have maximum absolute [Y,Cb,Cr] differences [1,1,1].

The protocol fixture resets at CE=0 during idle,capture,synchronous read,
chroma accumulation, held output and held DONE. Missing/extra SOF and EOL
errors each produce zero output followed by a healthy full-frame recovery;
four recovery frames/1536 samples and four invalid geometry cases PASS.
The main test automatically invokes this protocol fixture.

The first all-random maximum-width simulation exceeded its240-second VVP
budget with no reported DUT mismatch. It was stopped by the harness and its
temporary files removed. The final maximum-capacity fixture uses indexed
color bands (R=x>>8, G=x>>4, B=17*(x>>12), each reduced to8 bits), so VVP
can avoid repeated color-function reevaluation for identical adjacent RGB.
It still transfers all65536 source pixels and checks all1572864 real output
samples and MCU/marker positions. Normal-sized geometries retain random RGB
and exact conversion checks. verification_notes.json preserves this scope
and timeout history; no DUT output expectation was altered after a mismatch.

Isolated synth_gowin + check-assert PASS for16x16 /31x33 /65536x1:
LUT1..4=1065/1078/1136, ALU303/347/281, FF130/134/148,
RAM1/2/96 blocks, MUX2_LUT5=38/40/59, all **0 DSP**. The maximum stores
65536*24=1572864 RGB bits and maps to96 DPB blocks; default maps to one
SDPX9B and31x33 to two DPX9B. This is standalone mapping, not an integrated
device-fit or timing/board claim. Raw arithmetic/logic stays below15K at all
three tested capacities. Full encoder integration must account for the
frame RAM and other stages' concurrent resource use.

Only small evidence JSON files persist. Generated test streams/netlists and
large maximum-frame fixtures use TemporaryDirectory and are removed.
Not yet board verified. No security or side-channel claim.
