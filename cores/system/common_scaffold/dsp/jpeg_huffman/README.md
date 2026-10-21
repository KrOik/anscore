# Baseline JPEG default canonical Huffman lookup

`jpeg_default_huffman.sv` implements all four Annex K default Huffman tables:
12 luminance DC, 12 chrominance DC, 162 luminance AC and 162 chrominance AC
entries. Component 0 selects luminance, 1/2 select chrominance; component 3
is rejected. These default tables are for 8-bit baseline JPEG precision.
No runtime custom-table or progressive/arithmetic coding is implemented.

Input matches the existing `jpeg_entropy/jpeg_baseline_symbols.v` token
fields: DC flag, run[3:0], size[3:0], amplitude[15:0], block_end, restart and
component[1:0]. The existing symbolizer uses active-high rst; this module uses
synchronous active-low rst_n, so invert the shared reset when connecting it.
Each accepted legal token emits right-aligned code[15:0], code_bits[4:0],
the original right-aligned JPEG amplitude bits and amplitude_bits[4:0], plus
unaltered block_end/restart/component. Code/amplitude are emitted MSB-first by
the downstream packer. No amplitude sign conversion is done here: the
symbolizer already generates JPEG negative-value complement representation.

DC requires run=0 and category 0..11. AC requires size 1..10, or size=0
with run=0 (EOB) /15 (ZRL). Bits above the category width must be zero.
restart is permitted only on a DC token. Error codes are sticky fail-stop:
1 invalid component; 2 unsupported symbol/category or missing code; 3 amplitude
width; 4 restart on AC. Invalid tokens produce no output. Once an error is
latched s_ready remains low until reset; prior accepted output may still drain.
This is symbol validation, not block-sequence or restart-interval validation.

All transfers require **ce && valid && ready**. CE must be honored by both
neighbors. Output valid/payload remain stable through backpressure and CE
pauses. One elastic output register permits one accepted input per enabled
cycle, including simultaneous output consumption and input replacement. A
token accepted at an edge is presented valid immediately after that edge and
can be consumed at the next enabled edge. Synchronous reset overrides CE,
clears errors, and discards pending output. No table initialization is required.

**block_end is metadata, not a bitstream flush**. JPEG concatenates successive
blocks without per-block padding. restart is also only metadata here; a scan
controller must pad/flush before inserting a restart marker, and must flush
at the end of a scan. This lookup emits no bytes, stuffing, headers or markers.

## Actual network reference and independent evidence

The table counts and values were fetched over HTTPS from
[libjpeg-turbo jstdhuff.c](https://raw.githubusercontent.com/libjpeg-turbo/libjpeg-turbo/main/src/jstdhuff.c),
which labels the defaults as JPEG section K.3. `reference.json` records the
retrieved content SHA256. Only standard table counts/value data were used;
no libjpeg implementation was copied. `tables.py` exposes TABLES dictionaries
(counts is 16 lengths, values is symbol order) and canonical(**table), usable
by host code when generating DHT segments. The standalone RTL case ROM was
generated from an iterative canonical-code assignment; the test oracle uses
the independent direct first-code sum formula.

```
python -B cores/system/common_scaffold/dsp/jpeg_huffman/test_huffman.py
python -B cores/system/common_scaffold/dsp/jpeg_huffman/synth.py
```

Tests cover every one of 348 unique default codes and all 522 component/table
mappings, random legal amplitude bits and metadata, valid gaps, ready stalls,
CE pauses, elastic throughput/stability, eight illegal-token cases, sticky
fail-stop behavior and reset aborting stalled output while CE is disabled.
Temporary binaries are automatically removed. Small JSON evidence is retained.

Isolated Gowin synthesis (`-noalu -nodsp`) reports 472 LUT1-4,
35 MUX2_LUT5, 47 FF, zero DSP and zero memory cells. CHECK reports zero
problems. No P&R, clock target, decoder interoperability or board result is
claimed by this isolated lookup evidence.
