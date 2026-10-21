# Baseline grayscale JPEG decoder

`jpeg_gray_decoder.sv` implements a complete compressed-byte-to-raster pipeline: whole-file capture, SOI/APP/COM/DQT/DHT/SOF0/SOS parsing, canonical Huffman bit decoding, FF/00 byte unstuffing, differential DC and AC run-length decoding, zigzag placement, dequantization, two-pass 8x8 IDCT, level shift, saturation and cropped raster replay. This is a decoder; it does not require host-supplied coefficients or decoded pixels. No third-party RTL was copied.

## Supported interchange format

8-bit baseline sequential **one-component grayscale**, 1x1 sampling, exactly one scan, 8-bit nonzero quantization values, quant table IDs 0..3, Huffman destination IDs 0..3 and explicit tables within each file. Width/height may independently be 1..MAX_SIDE, including nonmultiples of eight; padded block pixels are cropped. Default MAX_SIDE=32 (accepted elaboration range 1..256), MAX_BYTES=8192. The hardware is deliberately serialized and frame-buffered, not a real-time video throughput claim. The synthesis evidence covers the default profile, not arbitrary maximum elaborations.

APP0..APP15 and COM payloads are skipped by declared length; marker FF fill bytes are supported. DQT and DHT may contain multiple/redefined tables. Huffman construction rejects oversubscribed trees and all-ones codes. Empty/partial table segments, absent referenced tables, zero quantization elements, out-of-range dimensions, bad sampling/scan fields, invalid entropy symbols/runs, premature entropy markers, bad padding, missing EOI and bytes after EOI terminate with error. Progressive, arithmetic, multicomponent/color, restart/DRI, hierarchical and abbreviated-table JPEG are explicitly unsupported. No attempt is made to silently decode these as grayscale. All-ones final entropy fill bits are required. This stricter exact-file boundary rejects trailers that some software decoders tolerate.

## Interface and recovery

`clk/rst_n/ce`, `start_valid/start_ready`, `abort`; input `s_data/s_valid/s_last/s_ready` carries one complete JPEG, `s_last` on its last byte. There is no input pixel SOF/EOL because this is a compressed-byte interface. `width/height` are decoded metadata. Output `m_data/m_valid/m_sof/m_eol/m_last/m_ready` is a single grayscale raster. `done_valid/done_ready/done_error/error_code/busy` reports terminal status. Only enabled valid/ready edges transfer tokens. Ready is suppressed during reset, CE=0 and abort. Output and DONE hold across CE pauses/backpressure. Acknowledging DONE allows a new file without reset, and tables are invalidated on every START.

Capture backpressures until the table-control initialization completes. Decode begins only after accepting `s_last`; a source that stops without `s_last` must use abort or reset. File truncation with `s_last` is detected by bounded memory fetch. No input-data watchdog is claimed. Every accepted compressed byte is fetched from synchronous storage. Table/scratch storage may infer LUTRAM; synthesis counts it conservatively.

Reset is synchronous, active low, and works even at CE=0. Abort suppresses output immediately and latches error on an enabled edge; keep it asserted until such an edge. Errors detected before replay produce no output. An abort during replay invalidates the entire frame, including pixels already sent. Late abort does not alter held DONE. Metadata/output marker values are meaningful only with the respective valid transaction.

Error codes: 80 invalid static geometry/byte capacity; 81 capture overflow; 82 truncated file; 83 SOI; 84 marker prefix; 85 unsupported marker/process; 86 segment length; 87 SOF; 88 SOS; 89 quant table; 8A Huffman table; 8B missing referenced table; 8C entropy marker/stuffing; 8D undecodable Huffman word; 8E DC category; 8F AC category/run; 90 DC predictor range; 91 entropy padding/EOI/trailer; 93 abort; 94 internal state.

## Arithmetic and numerical limits

DC category <=11, AC magnitude category <=10. DC differences are sign-extended and accumulated; this implementation explicitly rejects DC predictors outside [-2048,2047]. DC category 11 is a difference category, not proof that an arbitrary coefficient sequence comes from a physical 8-bit image. Signed 24-bit coefficient RAM holds dequantized coefficients, with conservative bound A=2048*255=522240; there is no signed-16-bit truncation. Input-domain quantized values and quantization factors multiply exactly.

IDCT uses the orthonormal matrix `T[x,u]=(1/sqrt(8) if u=0 else cos((2x+1)u*pi/16)/2)`, rounded to signed 28-bit **Q26** constants. A shared bit-serial shift/add multiplier runs 28 steps and uses no DSP. First-pass values are rounded to nearest integer with ties toward +infinity and held in signed24. For delta=2^-27, every rounded row has absolute sum <=sqrt(8)+8*delta. Thus first-pass magnitude <=A*(sqrt(8)+8*delta)+0.5 <1,477,120 <2^21, safely below signed24 capacity. The second-pass unshifted sum is bounded by 1,477,120*(sqrt(8)+8*delta)*2^26 <2^49; signed56 accumulator/product storage is sufficient.

Relative to an ideal real-valued orthonormal IDCT before final rounding, matrix quantization contributes <=64*A*(delta+delta^2)<0.25 gray levels and first-pass rounding contributes <=0.5*(sqrt(8)+8*delta)<1.415. Therefore pre-final-round discrepancy is <1.665, implying at most **2 integer gray levels** versus identically rounded ideal output; clipping cannot enlarge it. This is a mathematical fixed-point bound within the explicit coefficient domain, not a universal libjpeg bit-exactness claim.

Ordinary Pillow-generated fixtures (qualities 1..100, normal and optimized Huffman tables) compare to an independent Pillow/libjpeg decode, with observed maximum error **1** and test limit 2. Four deliberately extreme entropy-category stress streams have dequantized magnitudes up to 521985, beyond normal reconstructed 8-bit sample dynamic range. They compare to an independent NumPy double-precision orthonormal IDCT: observed error **0**. On those same stress streams Pillow differs by as much as **255**; the evidence records that divergence explicitly. Libjpeg's limited-range IDCT/range-limit behavior must not be used as a universal oracle for such extreme coefficient combinations. These cases demonstrate wide arithmetic, not physical-image validity or universal Pillow equivalence.

## Reproduce

From repository root:

```powershell
python -B cores/system/common_scaffold/image/jpeg_gray_decoder/run_tests.py
python -B cores/system/common_scaffold/image/jpeg_gray_decoder/test_protocol.py
python -B cores/system/common_scaffold/image/jpeg_gray_decoder/test_numeric_limits.py
python -B cores/system/common_scaffold/image/jpeg_gray_decoder/synth.py
```

`generate_coefficients.py` reproduces the required ROM asset. `evidence.json`, `protocol_evidence.json`, `numeric_evidence.json` and `synthesis.json` include current RTL/ROM SHA256. Functional tests exercise enabled stalls, output hold, marker consistency, back-to-back files and held DONE. Every malformed-file case is followed by a healthy independent Pillow-generated file without reset. Protocol tests abort seven internal phases and reset during a multiply while CE=0, then decode healthy frames. Temporary simulation/synthesis directories are automatically removed. No board acceptance or post-route timing result is claimed.

References in `references.json` record downloaded T.81 and libjpeg-turbo Huffman/IDCT reference hashes. Study points were T.81 Annex B table/scan syntax, Annex C canonical construction/all-ones reservation and Annex F sign extension/block reconstruction. The implementation uses a straightforward original matrix IDCT, not the copied libjpeg fast integer algorithm. The downloaded reference sources/PDF are removed after inspection.
