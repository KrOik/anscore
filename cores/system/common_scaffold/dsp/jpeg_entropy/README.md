# JPEG baseline coefficient symbol front-end

`jpeg_baseline_symbols.v` converts **already zigzag-ordered quantized** 8x8
coefficient blocks into baseline JPEG entropy symbols. It implements component
DC prediction, signed category/amplitude coding, AC run/category generation,
ZRL and EOB. It does not perform DCT, quantization, zigzag reordering, Huffman
table lookup, bit packing, byte stuffing, marker emission or JPEG container
creation. A generic RLE codec is not equivalent to these JPEG semantics.

## Input and output ABI

Parameters: COEFF_W=2..16 (default 16), COMPONENTS=1..4 (default 3).
`s_coefficient` is signed COEFF_W bits. Exactly 64 input transfers make a
block, indexed 0..63 in JPEG zigzag order. `s_first` must identify index 0;
`s_last` must identify index 63. `s_component` is two bits and must be a legal
component index, constant through the block. Component DC predictors are
independent, initialized to zero. Coefficient input width is a transport
width, not permission to emit extended JPEG categories: this implementation
is for **8-bit baseline** coefficient limits (DC difference category <=11,
AC coefficient category <=10), not 12-bit extended sequential JPEG.

The output token is held while token_valid until token_ready. Fields:

| field | meaning |
|---|---|
| token_dc | 1=DC difference; 0=AC run/category |
| token_run[3:0] | preceding AC zero count for ordinary symbol; 0 for DC |
| token_size[3:0] | amplitude bit count/category |
| token_amplitude[15:0] | amplitude right-aligned in low size bits |
| token_block_end | final token of this coefficient block |
| token_restart | DC-only event, reset predictors before this block |
| token_component[1:0] | component index for selecting caller Huffman table |

For nonzero v, category = floor(log2(abs(v)))+1. Positive amplitude=v;
negative amplitude=v+(2^category-1), equivalent to JPEG magnitude-complement
coding. DC zero uses size=0 and amplitude=0. Upper amplitude bits are zero.
The caller chooses a DC Huffman symbol of `size`, or an AC Huffman symbol
`(run<<4)|size`, then appends the low `size` amplitude bits MSB-first.

Special AC tokens:

- ZRL: run=15, size=0, amplitude=0, block_end=0, represents 16 zeros.
- EOB: run=0, size=0, amplitude=0, block_end=1, represents all remaining zeros.

Trailing zeros use one EOB, never gratuitous trailing ZRL. A nonzero final
coefficient emits any preceding ZRL tokens followed by its ordinary run/size
symbol with block_end=1, and **no EOB**. DC is never a block-ending token.
A block can contain one DC and one EOB even though all 64 coefficients are
zero. Long nonzero-preceding runs consume a coefficient once, then emit
multiple held tokens before accepting another input.

## Restart, errors, reset and CE

`s_restart` is legal only at DC and means the restart boundary occurs
**before** this block. On its acceptance all component predictors reset to
zero before the current DC difference is evaluated; the current component
then records this coefficient as its new predictor. token_restart appears
only on that DC token. It is an event hint, **not an emitted RST marker**.
The caller must finish/stuff/pad/flush the preceding entropy bytes and insert
the appropriate RST marker before coding the indicated DC. Marker numbering
and restart interval scheduling are external. No predictor resets occur merely
because the component changes.

Every transfer is `ce && valid && ready`. CE=0 freezes all state, payload and
sidebands; output valid can remain high. Input ready is low while paused,
while any token is pending, or after a fatal input error. Endpoints must obey
this CE-qualified contract. No coefficient/token is consumed on a disabled
clock. Zero AC coefficients can be accepted on adjacent enabled clocks;
a coefficient that emits a token makes it visible after its accepting edge.
Token-producing coefficients have an input bubble while their output drains.

Error codes are sticky until reset:

| code | cause |
|---:|---|
| 0 | no error |
| 1 | incorrect first/last marker |
| 2 | component outside range or changed within a block |
| 3 | DC difference category exceeds 11 |
| 4 | AC coefficient category exceeds 10 |
| 5 | restart asserted at an AC coefficient |

The offending input is consumed, no token is emitted for it, and the module
stops accepting coefficients until reset. Earlier tokens cannot be revoked;
the caller must discard/restart its failed scan as appropriate. Check precedence is marker, component, restart placement, then category;
malformed markers therefore take precedence over coefficient limits.
Synchronous active-high rst overrides CE, discards any partial block/pending
token, clears errors, and resets all predictors. There is no full-block RAM
or coefficient buffering: only predictors, run count and one pending symbol.

## Verification and resource evidence

```
python -B cores/system/common_scaffold/dsp/jpeg_entropy/test_jpeg_symbols.py
python -B cores/system/common_scaffold/dsp/jpeg_entropy/synth_jpeg_symbols.py
```

The independent Python oracle processes JPEG symbol sequences directly,
using integer bit_length and coefficient lists rather than RTL state logic.
47 blocks (3008 coefficients) produce 742 exactly compared tokens. Tests
include all-zero blocks, runs around 16/32/48-zero boundaries, final nonzero,
all ten legal AC categories with both signs, DC +/-2047 differences,
component prediction, restart resetting other components, sparse/dense random
blocks, random input gaps/CE/output stalls and held payload stability. Five
terminal error classes, signed -32768, immediately out-of-range categories,
component changes and reset abort/predictor reset are exercised. Four illegal
static parameter combinations fail simulation. Temporary fixtures and
binaries are automatically deleted; small JSON results remain here.

The symbol rules were cross-checked with upstream libjpeg-turbo's baseline
entropy encoder `jchuff.c`, specifically its 0xF0 emission for runs >15 and
remaining-zero EOB logic:
https://github.com/libjpeg-turbo/libjpeg-turbo/blob/main/src/jchuff.c .
No source code from that project is copied into this RTL or oracle.

Isolated `synth_gowin` mapping, no family/P&R:

| COEFF_W / COMPONENTS | LUT1-4 | ALU | FF | DSP/RAM |
|---|---:|---:|---:|---:|
| 12 / 1 | 198 | 53 | 54 | 0 / 0 |
| 16 / 3 | 307 | 65 | 90 | 0 / 0 |

MUX5 cells are separately recorded in synthesis_result.json. No timing closure,
board verification, full JPEG file decoding, or Huffman coding is claimed.

