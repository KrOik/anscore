# INT4 Winograd tile cross-correlation

Original Apache-2.0 RTL. Current status: **RTL_CANDIDATE,
INTEGRATION_CANDIDATE, HW_UNVERIFIED; all executable checks NOT_RUN**.
Baseline c9117a22459e954d496dfa66dd94d6f67188c862. No historical evidence
is claimed for these new modules or their composition.

One command captures a 4x4 U8 tile and asymmetric U8 input zero, then emits
the exact 2x2 VALID cross-correlation for each of 1..MAX_ROWS resident S4
3x3 kernels, including a S32 row bias. It shares the input transform and uses
one serial signed11 x signed8 transformed product. Unlike the existing direct
int4_conv3x3_frame engine this is a Winograd tile architecture. It does not
receive a raster frame, pad borders, sum input channels or train weights.

## Source closure and use

`rtl/int4_winograd_tile.sv` is standalone. `files.f` paths are relative to
this package. `example/files.f` paths are relative to `example/`; it includes
the new core, new `winograd_requantize` wrapper and the unchanged local
`../../int4_weight_matvec/rtl/deps/stream_requantize.v`. This is the retained
baseline alias of stream_requantize, with identical canonical source bytes.
No network, memory image,
generator, vendor library or external memory is needed to use the RTL.
Model/TB files are separate verification aids and are not synthesizable IP.

Instantiate `int4_winograd_tile #(.MAX_ROWS(8),.TAG_W(16))` with the ports
listed in the RTL, or `winograd_requantize` with the same configuration,
command, sample and response ports. Set MAX_ROWS=1..64, TAG_W=1..32.
The example performs actual RNE/clip using the existing production quantizer;
it is not a mock. Compile a selected top using its file list in the stated
working directory after the finite-execution review gate.

## Common transfer rules

All ports use one rising-edge clock. `rst` is synchronous high and clears
validity, in-flight work, responses and published rows. Reconfigure after
reset; previously accepted output prefixes cannot be retracted. There is
no CE, CDC, abort or memory port. All handshakes are ordinary `valid && ready`
at a rising edge with reset low. Producers hold their entire payload stable
while valid and not ready. Outputs and all their metadata remain stable
under backpressure. Interface valid/ready is low while reset is high.
`busy` is `state!=IDLE`; it clears on the reset clock edge and is not
combinationally masked by reset before that edge.

Only one configuration operation or tile command can own the engine.
Configuration wins if both are offered while idle; the unaccepted command
must remain offered. Configuration is blocked until the preceding final
response retires, and a held configuration reply blocks commands. No implicit
configuration switch occurs while output or a final response is held.

## Configuration: explicit publication

All configuration payloads are captured only on `c_valid && c_ready`.
`c_rsp_valid` holds `c_error` until `c_rsp_ready`. Rejected operations are
atomic and preserve row payload/validity. Row indices are unsigned16; tap
indices unsigned4. Input S4 weights use two's complement, not offset binary.

| c_op | Effect |
|---:|---|
| 0 | Write c_weight to row c_row, row-major tap c_tap=0..8; unpublish this row |
| 1 | Write S32 bias, U16 scale, U6 shift=0..31 and S8 zero; unpublish this row |
| 2 | Publish c_row only after all nine taps and metadata are present; compute/store its exact integer kernel transform |
| 3 | Invalidate all taps, metadata and publications; row/tap payload ignored |

`c_error`: 0 success; 1 row/tap outside the operation's domain; 2 invalid
shift; 3 publish without all taps/metadata. Row/tap fields irrelevant to an
operation are ignored. Op3 clears validity without clearing RAM payload.
Published rows can be republished/reused across many tiles. Writing any valid
tap or metadata invalidates the publication, even when the value is unchanged.
Publication holds config ready low for 46 work cycles; see architecture.

## Tile command, input and response

`cmd_rows` is unsigned16 (1..MAX_ROWS), `cmd_x_zero` U8 and `cmd_tag` opaque
TAG_W bits. Rows always mean the prefix 0..cmd_rows-1. A precheck ensures the
whole prefix is published before accepting input. Illegal row count returns
`rsp_error=1`; missing publication returns 2. These errors accept zero samples
and emit zero results. `rsp_tag` echoes the captured command tag, and
`rsp_outputs=0` for either rejection.

A valid command accepts exactly sixteen U8 samples in row-major 4x4 order.
Input LAST must be low on samples 0..14 and high on sample15. Any mismatch
is accumulated, but all sixteen samples must still be supplied; no early
packet termination or input resynchronization is inferred. All four results
per row are still emitted and are provisional until final `rsp_error` is
known. Framing mismatch returns 3, otherwise 0. The caller must discard or
account for an invalid transaction as its application requires.

The core emits channel/row major, then 2x2 pixel row-major: pixel0=(0,0),
1=(0,1),2=(1,0),3=(1,1). `m_acc` is exact signed33 bias+dot, `m_row` U16,
`m_pixel` U2, `m_tag` captured tag; `m_last` is true only at the last pixel
of the last row. Per-row scale U16, shift U5 and zero S8 accompany each
result. They do not affect the raw accumulator. Output stalls stop row
advancement; no later sample/command is accepted during computation.

After all public outputs retire, a held final response reports `rsp_error`,
actual `rsp_outputs=4*cmd_rows` (U9, up to256) and tag. It retires only on
`rsp_ready`. No result is silently dropped because the response is held.

## Real requantization example

`example/winograd_requantize.sv` outputs S8:

```
sat8(RNE_to_even((signed33_acc * unsigned16_scale) / 2^shift) + signed8_zero)
```

Multiplication has exact signed50 precision; RNE occurs before adding zero.
`m_clip` indicates final clipping, `m_inexact` indicates discarded nonzero
fraction bits (independent of clipping). Scale0, shift0, positive/negative
ties and extreme biases are legal. The existing quantizer's S16 intermediate
cannot change the final S8 answer: clipping beyond S16 remains beyond S8
for every allowed zero. Metadata travels through the same elastic stages.
The wrapper holds the core final response until its scaling register and
three quantizer registers drain. Reset flushes all four stages and the core.
Four entries of in-flight capacity do not overlap tile commands.

See ARCHITECTURE.md for numeric bounds, storage and no-stall cycle budget,
SOURCES.md for the fixed public algorithm reference, and FINITE_PLAN_DRAFT.md
for the unexecuted verification boundary. No LUT/DSP/Fmax/power or hardware
qualification claim is made.
