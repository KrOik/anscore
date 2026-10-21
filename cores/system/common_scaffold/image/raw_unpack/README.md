# CSI-2 RAW10 / RAW12 payload unpacker

`img_csi2_raw_unpack` converts one packed payload byte per input transfer into
one native unsigned RAW pixel per output transfer. This is payload processing:
it contains no D-PHY, lane deskew, CSI-2 packet header parsing, ECC/CRC or Bayer
interpolation. Place it after a receiver has stripped packet headers/checksums
and annotated frame/line boundaries. It does not infer Bayer color positions.

Repository search found existing expanded RAW10/RAW12 Bayer kernels and tests,
but no equivalent packed-byte production unpacker in the common IP library.

## Exact byte order

Instantiate with compile-time `RAW_BITS=10` (default) or `12`.

| Format | Accepted payload bytes in order | Reconstructed pixels |
| --- | --- | --- |
| RAW10 | `A[9:2], B[9:2], C[9:2], D[9:2], {D[1:0],C[1:0],B[1:0],A[1:0]}` | A, B, C, D |
| RAW12 | `A[11:4], B[11:4], {B[3:0],A[3:0]}` | A, B |

Examples: RAW10 pixels `0,1,2,1023` pack into `00 00 00 FF E4`;
RAW12 pixels `ABC,123` pack into `AB 12 3C` (hex bytes/pixels in second example).
This is not continuous little-endian bitstream packing or unpacked 16-bit RAW.
The byte order was independently cross-checked against the Linux V4L2 packed Bayer
documentation: [RAW10P](https://docs.kernel.org/userspace-api/media/v4l/pixfmt-srggb10p.html),
[RAW12P](https://docs.kernel.org/userspace-api/media/v4l/pixfmt-srggb12p.html).
The RAW12 reference explicitly places the second pixel's low nibble in bits 7:4
and the first pixel's low nibble in bits 3:0. No external RTL was copied.

## Streaming contract

Input is `s_data[7:0]`, `s_valid/s_ready`, `s_sof`, `s_eol`.
Output is `m_data[RAW_BITS-1:0]`, `m_valid/m_ready`, `m_sof`, `m_eol`.
Transfers occur on rising clock edges with `clk_en && valid && ready`.
Upstream must hold bytes and markers stable until accepted. Output valid remains
asserted under backpressure or disabled CE; payload/markers remain stable.
`s_ready` is low during reset, disabled CE, invalid parameter, or group emission.
The consumer must also use the CE-qualified transfer convention.

The complete group is buffered before any of its pixels are emitted. Input and
output groups do not overlap: ideal rates are 4 pixels per 9 enabled edges for
RAW10 and 2 per 5 for RAW12. The first output becomes valid immediately after
the group's final byte is accepted, and can transfer on the next enabled edge.
No partial group is emitted. Frame SOF on a group's first byte is carried on its
first pixel; EOL on the final packed byte is carried on its last pixel.
Each row must contain a multiple of 4 RAW10 pixels or 2 RAW12 pixels. Rows are not
implicitly combined; an explicit EOL is required if downstream needs line markers.

`rst_n` asynchronously clears all state, pending group/output and errors. Reset
may discard any partial or stalled complete group; no end marker is invented.
There is no timeout for missing payload bytes. A missing EOL cannot be detected
without an external row-length/packet-word-count checker. Complete groups may be
decoded before the first SOF; SOF is a marker, not permission to enable decoding.

## Error and resynchronization rules

`protocol_error` is sticky until reset. `error_pulse` is asserted for one enabled
clock edge per malformed accepted byte (and remains held while CE is disabled).
`error_code[1:0]` retains the most recent error until reset or a later error.
These status signals are not a ready/valid queue; sample with CE or latch sticky
status. Consecutive malformed bytes may keep the pulse high on adjacent edges.

| Code | Condition | Recovery |
| --- | --- | --- |
| 1 | EOL on any byte other than the group's final LSB byte, or simultaneous SOF/EOL | Discard this byte and all pending partial-group bytes; next byte starts a new group |
| 2 | SOF arrives while a partial group exists, without EOL | Discard old partial bytes; this same SOF-marked byte starts the new group |
| 3 | Unsupported positive `RAW_BITS` parameter | Input ready remains low and no pixels emit; sticky error and one initial enabled-cycle pulse |

Code 1 takes precedence over code 2. Previously emitted groups cannot be rolled
back: if a row ends with an incomplete group, the earlier groups in that row
have already transferred and receive no retroactive EOL. A downstream frame store
should discard the damaged frame using sticky error or a captured error event.
An upstream CSI receiver that pads a short last group to a complete standard
group must separately crop unwanted pixels; this module does not know image width.

## Verification and synthesis

Run from repository root:

```powershell
python -B cores/system/common_scaffold/image/raw_unpack/run_tests.py
```

The Python oracle generates original native pixel values, packs them, and compares
all output pixels and SOF/EOL against the originals in SV. It includes manual byte
examples, random values, zero/max values, randomized source gaps, CE and sink
pauses, output stability, all partial-group EOL positions, all partial SOF positions,
reset abort of partial/stalled full groups and unsupported-parameter rejection.
Evidence: `test_result.json`; RAW10 1888 pixels / 9 errors and RAW12 840 pixels /
5 errors PASS. Temporary vectors and simulator binaries are automatically removed.

Isolated synthesis commands (`yosys` requires OSS CAD Suite bin/lib on PATH):

```powershell
yosys -Q -T -p "read_verilog cores/system/common_scaffold/image/raw_unpack/img_csi2_raw_unpack.v; synth_gowin -top img_csi2_raw_unpack -noalu -nolutram; stat"
yosys -Q -T -p "read_verilog cores/system/common_scaffold/image/raw_unpack/img_csi2_raw_unpack.v; chparam -set RAW_BITS 12 img_csi2_raw_unpack; synth_gowin -top img_csi2_raw_unpack -noalu -nolutram; stat"
```

Both modes report CHECK 0 problems, no DSP or BRAM. See the retained small
`synthesis_raw10.log` and `synthesis_raw12.log` for exact mapped counts. No layout,
clock timing, JTAG, physical CSI receiver or camera-image validation was performed.
The parent owns integration into shared source manifests and test runners.
