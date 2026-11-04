# B20 provenance and semantic boundary

Baseline actual HEAD was checked as
`ff2aadf8ebdc8e5475b7022cd68d47e496b9f593` before development.

An initial geodesic grayscale reconstruction candidate was rejected after actual
whole-repository production/README searches found the existing complete
`cores/system/common_scaffold/image/morph_reconstruction` implementation. Its
actual contract includes both dilation/erosion and4/8 connectivity. No file was
created for that candidate, and no old implementation was modified.

Repository-wide searches of actual production RTL and README/SOURCES for QOI,
Quite OK, related codecs and byte compression found no QOI service. Actual
contracts of png_decoder/png_encoder, jpeg_color_decoder, raw16_codec and
binary_rle were read. PNG parses DEFLATE/filter/checksum containers, JPEG entropy
and IDCT, RAW16 packs samples and binary_rle exchanges binary image run tokens;
none supplies QOI's color index/difference/luma/run file interpretation. This
package does not rename a codec, alter its bit width or add a geometry statistic.

## Fixed complete upstream read before RTL

Repository:<https://github.com/phoboslab/qoi>

Fixed commit:`ffb2d2cb74a1de60819b21b939f7209aa53e91c1`

|Complete file actually fetched/read|Bytes|SHA256|
|---|---:|---|
|[qoi.h](https://github.com/phoboslab/qoi/blob/ffb2d2cb74a1de60819b21b939f7209aa53e91c1/qoi.h)|18326|7de6fca1a285b1c20d38f2723dec8b774eb9f144edb9710800a95feeea09375a|
|[LICENSE](https://github.com/phoboslab/qoi/blob/ffb2d2cb74a1de60819b21b939f7209aa53e91c1/LICENSE)|1075|0caf25d92ae0e7e12107e144a86782ccaad37ddaa3ee51e86e193c7db9ed1487|

Both complete files were retrieved read-only through fixed raw GitHub URLs and
strict UTF8 decoded before local RTL. qoi.h contains full format documentation,
all encoder/decoder helper/implementation functions and file wrappers; all were
read. Its header credits2021 Dominic Szablewski and carries SPDX MIT. The full
repository MIT license credits2022 Dominic Szablewski; these dates are recorded
as printed rather than silently unified. The file's performance claims are
upstream context and are not local FPGA measurements.

No external source, comments, test, license text, binary or build dependency was
copied, adapted, translated, persisted locally, imported, installed or executed.
The fixed source was format/reference inspection only and untrusted remote text
was not treated as agent instructions. The local RTL, encoder oracle, testbench,
fixtures and documentation are independently authored repository Apache-2.0 work.
No third-party adopted code requires an added license copy; root LICENSE/NOTICE
retain their exact bytes. No network, QOI C library, Pillow, NumPy or external
decoder is required to use or reproduce the finite local package offline.

The source's C decoder uses malloc/color arrays and permissive unchecked
malformed-stream handling, without verifying the actual ending bytes. The local
hardware has bounded synchronous byte/pixel/index memories, valid-bit ownership,
full-file validation before visibility, exact pixel-count/run bounds, verified
ending and the valid-encoder consecutive-INDEX restriction. The explicit accepted
domain and error order in README govern this implementation; no malformed-file
equivalence to the upstream decoder is asserted.

The local oracle works in the opposite direction from hardware: it selects
legal chunks from original pixel sequences, and retains those pixels as expected
output. Six mathematical one-pixel opcode anchors, transparent cache defaults,
hash collisions and explicit malformed files supplement it. It does not call or
port the upstream decoder. `.gitattributes` was the first local file created;
all final local assets are UTF8/LF. Production closure is one local source and
the example adds only one local wrapper. No old package or shared file is linked
or edited, and no synthesis/PnR/STA/board activity is part of this task.
