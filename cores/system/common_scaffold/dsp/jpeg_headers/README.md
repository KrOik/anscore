# Grayscale baseline JPEG header and marker byte emitter

`jpeg_gray_headers.sv` emits real JPEG marker/segment bytes for **8-bit,
single-component grayscale baseline sequential JPEG**. It is not a color JPEG
header generator or a complete codec. Component ID is 1, sampling is 1x1,
quantizer ID is 0, and default Annex K luminance DC/AC Huffman tables use IDs 0.
No APP/JFIF/Exif metadata is needed or emitted.

Runtime dimensions are unsigned 16-bit, legal 1..65535. The host writes a
64-entry unsigned 8-bit natural-order quantizer table (all entries 1..255),
then commits width, height and restart interval through cfg_valid/cfg_ready.
Every table entry must have been written since reset. Incomplete tables or
zero dimensions pulse cfg_error immediately. Complete tables are scanned for
zero entries, then copied into active RAM; cfg_done follows only after the
entire 256-enabled-cycle validation/copy completes. A rejected commit preserves
the previous active dimensions, interval and table. Table writes, commits and
commands are serialized while busy. Commit has priority over a staging write;
staging writes have priority over a command. After reset commands are rejected
until the first legal configuration is committed.

Command values:

| cmd | emitted bytes |
| --- | --- |
| 0 | SOI, DQT, SOF0, DHT, optional DRI, SOS |
| 1 | EOI (`FF D9`) |
| 2 | restart marker (`FF D0` through `FF D7`), selected by rst_index |
| 3 | cmd_error pulse, no output |

Header command length is 306 bytes with interval zero, 312 otherwise. DQT
length is 67, SOF0 length 11, combined DC+AC DHT length 210, DRI length 4,
SOS length 8; segment lengths include their own two-byte length field but not
the marker. Dimensions, interval and lengths are big-endian. DQT serializes
the natural-order table in standard JPEG zigzag order. DHT contains precisely
the same default luminance counts/values as `../jpeg_huffman/tables.py`.
SOS sets Ss=0, Se=63 and Ah/Al=0.

Output bytes are **raw marker/header bytes and must not pass through entropy
byte stuffing**. An FF in quantizer data is emitted as FF, without an inserted
zero. m_last marks the last byte of a command; cmd_done pulses when that byte
is accepted. Byte reads are synchronous; first valid appears two enabled edges
after command acceptance, subsequent bytes have II=3 enabled cycles without
stalls. All handshakes require **ce && valid && ready**. Neighbors must honor
the same CE contract; pending valid/data/last remain stable on CE pauses and
backpressure. Reset is synchronous active-low, overrides CE, discards pending
commands and clears configuration/table-valid state.

The caller controls scan sequencing. This emitter does not count MCUs, pad
entropy bits, flush a bitpacker, cycle restart indices automatically, reset DC
predictors, or prevent a premature EOI. Before emitting RST or EOI, the scan
controller must flush/pad entropy data and drain stuffing; restart intervals
must match the configured DRI and RST sequence. Partial-edge 8x8 image blocks
must be padded by the upstream pixel/block engine. cmd_error/cfg_error are
pulses lasting one enabled cycle; errors do not poison later commands.

## Evidence and references

```
python -B cores/system/common_scaffold/dsp/jpeg_headers/test_headers.py
python -B cores/system/common_scaffold/dsp/jpeg_headers/synth.py
```

The test independently parses all emitted segments and lengths for 1x1, 8x8,
13x9 and 65535x65535 with zero/nonzero/maximal DRI. It checks standard DQT
permutation, raw FF table data (no stuffing), all eight RST markers, EOI,
default DHT agreement, invalid/incomplete/zero configurations and retained
active-table replay, illegal commands, CE/ready stalls, payload stability,
terminal done and reset during a stalled header. Three small headers plus
independently coded all-zero coefficient scans decode with Pillow to exact
128 grayscale samples, including restart decoding on the 13x9 fixture.
The 65535x65535 case is parser-only to avoid allocating a multi-gigabyte image.
The decoder scan is host-generated; this isolated test does not claim an
end-to-end pixel-to-JPEG RTL encoder.

Marker field layout was checked against the actual HTTPS-fetched
[libjpeg-turbo jcmarker.c](https://raw.githubusercontent.com/libjpeg-turbo/libjpeg-turbo/main/src/jcmarker.c).
`reference.json` records content SHA256; implementation is original. DHT data
uses the standard table reference already recorded in `../jpeg_huffman/`.

Isolated Gowin synthesis (`-noalu -nodsp`) reports 370 LUT1-4,
40 MUX2_LUT5, 2 MUX2_LUT6, 215 FF, 40 RAM16SDP4, 1 SPX9 and zero DSP.
CHECK reports zero problems. No P&R, clock-rate or board result is claimed.
Temporary binaries are automatically removed; bounded JSON evidence/logs stay.
