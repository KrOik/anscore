# CSI-2 RAW10 / RAW12 payload packer

`img_csi2_raw_pack` converts native unsigned pixels to standard packed payload
bytes. It complements `../raw_unpack/img_csi2_raw_unpack.v`. Repository source
search found that unpacker, but no existing equivalent production packer. This
module does not generate CSI-2 headers, word count, ECC/CRC, lane scheduling or
D-PHY signaling; add a packet transmitter downstream.

## Packing and markers

Compile-time `RAW_BITS=10` (default) accepts four 10-bit pixels A,B,C,D and emits:

```
A[9:2], B[9:2], C[9:2], D[9:2], {D[1:0],C[1:0],B[1:0],A[1:0]}
```

`RAW_BITS=12` accepts two 12-bit pixels A,B and emits:

```
A[11:4], B[11:4], {B[3:0],A[3:0]}
```

Examples: RAW10 `0,1,2,1023` -> hex bytes `00 00 00 FF E4`;
RAW12 hex pixels `ABC,123` -> hex bytes `AB 12 3C`.
This byte order agrees with the Linux packed Bayer documentation reviewed for
the companion unpacker: [RAW10P](https://docs.kernel.org/userspace-api/media/v4l/pixfmt-srggb10p.html)
and [RAW12P](https://docs.kernel.org/userspace-api/media/v4l/pixfmt-srggb12p.html).
No external RTL was copied. It is not continuous bitstream packing or unpacked
16-bit container formatting, and it does not change the Bayer color order.

Input signals: `s_data[RAW_BITS-1:0]`, `s_valid/s_ready`, `s_sof`, `s_eol`.
Output signals: `m_data[7:0]`, `m_valid/m_ready`, `m_sof`, `m_eol`.
SOF on the first pixel of a group annotates the first output byte. EOL on the
last pixel annotates the final shared-LSB byte. Rows must have a multiple of four
pixels for RAW10 or two for RAW12. No implicit padding or crop count is emitted.

## Transfer, stalls and reset

Both sides transfer on rising edges with `clk_en && valid && ready`. Upstream
holds a pending pixel and markers until accepted; downstream must obey the same
CE-qualified convention. Output valid and payload remain stable when CE is low
or the consumer is not ready. `s_ready` is low during reset, disabled CE, output
group emission and unsupported parameter settings.

A complete input group is buffered before any output byte is exposed. Input and
output groups do not overlap, so ideal throughput is four pixels/five bytes per
nine enabled edges for RAW10 and two pixels/three bytes per five enabled edges
for RAW12. First-byte valid appears after the last input pixel's acceptance edge;
the earliest first-byte transfer is the next enabled edge.

Asynchronous low `rst_n` aborts pending partial or complete groups and clears
status; no synthetic SOF/EOL is generated. There is no missing-pixel timeout or
row-width counter. A missing EOL cannot be diagnosed without an external packet
length checker. Complete groups before the first SOF are permitted; SOF is a
marker, not an enable condition.

## Malformed-input handling

`protocol_error` is sticky until reset. `error_pulse` indicates an event for one
enabled cycle; it holds during disabled CE and may be continuously high for
consecutive malformed accepted pixels. `error_code[1:0]` retains the latest code.
These signals are status, not a ready/valid error queue.

| Code | Trigger | Recovery |
| --- | --- | --- |
| 1 | EOL before the group's last pixel, or simultaneous SOF/EOL | Discard the current pixel and accumulated partial group; next pixel starts a fresh group |
| 2 | SOF while a partial group is buffered, with no EOL | Discard the old partial group; this same accepted pixel starts the new group |
| 3 | Unsupported positive RAW_BITS value | No input acceptance/output; sticky error with one initial enabled-cycle pulse |

Code 1 has priority over code 2. A damaged partial group emits no bytes, but
earlier complete groups may already have transferred; they cannot be rolled back
or retrospectively annotated EOL. Packet/frame storage should discard the damaged
row/frame using status. An application needing partial-row padding must perform
that padding and preserve valid-pixel counts outside this module.

## Reproduce and evidence

From repository root:

```powershell
python -B cores/system/common_scaffold/image/raw_pack/run_tests.py
```

The independent Python oracle computes expected bytes directly from original
native pixels and includes manual published-format examples. SV compares every
packer byte and its SOF/EOL against this oracle, then drives the actual companion
unpacker and compares every recovered pixel/marker against the original pixels.
Thus complementary pack/unpack mistakes cannot pass solely by cancelling out.
Random values, zero/max pixels, source gaps, link gating, consumer backpressure,
CE pauses, output stability on both modules, every partial EOL/SOF position,
partial/complete-group reset cancellation and unsupported-parameter rejection
are covered. Temporary vectors and simulator executables are removed automatically.

Current `test_result.json`: RAW10 2650 bytes / 2120 pixels / 7 error events PASS;
RAW12 1512 bytes / 1008 pixels / 3 error events PASS; invalid RAW_BITS=8 PASS.
It records packer and actual unpacker dependency hashes.

With OSS CAD Suite bin/lib directories on PATH, isolated synthesis is:

```powershell
yosys -Q -T -p "read_verilog cores/system/common_scaffold/image/raw_pack/img_csi2_raw_pack.v; synth_gowin -top img_csi2_raw_pack -noalu -nolutram; stat"
yosys -Q -T -p "read_verilog cores/system/common_scaffold/image/raw_pack/img_csi2_raw_pack.v; chparam -set RAW_BITS 12 img_csi2_raw_pack; synth_gowin -top img_csi2_raw_pack -noalu -nolutram; stat"
```

Retained small logs report CHECK 0 problems: RAW10 60 LUT1..4 + 11 MUX2_LUT5,
52 FF; RAW12 42 LUT1..4 + 11 MUX2_LUT5, 36 FF; both 0 DSP/BRAM. These are isolated
mapping counts, not physical timing signoff. No JTAG, camera, actual CSI-2 link,
placement/routing or setup/hold validation was performed. Shared manifest and
runner integration remains the parent task's responsibility.
