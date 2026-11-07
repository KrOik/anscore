# RGB screen matte and green/blue spill suppression

Original Apache-2.0 `rgb_screen_matte` produces continuous opacity and
premultiplied RGBA paint from an opaque RGB888 source. Runtime key color,
distance thresholds, screen channel and suppression strength belong to each
accepted pixel. It has no frame or line memory. The actual example pairs
the source with a supplied premultiplied background and uses unchanged
`rgba_porter_duff` source-over arithmetic.

Status: **DRAFT / SOURCE_ONLY / EXECUTION_PENDING / HW_UNVERIFIED**. No model,
helper, AST, HDL or physical tool has been run for this package. Source review
does not establish simulation or hardware qualification. Baseline is
`c9117a22459e954d496dfa66dd94d6f67188c862`; B49 sources remain frozen.

## Numerical contract

`s_rgb` and `s_key` are unsigned `{R8,G8,B8}` in a common caller-defined byte
color space. This core does not apply gamma, transfer conversion or automatic
screen-color estimation. Its opponent coordinates are `u=B-G`, `v=R-G`.
Let `D2=(u-uk)^2+(v-vk)^2`. Each difference is in[-510,510], each square is
at most260100 and the complete exact sum is at most520200, fitting19 bits.
Alpha is computed from the **original** RGB, before spill correction.

`s_inner2` and `s_outer2` are unsigned19 squared-distance thresholds. The whole
0..524287 port range is legal; a threshold beyond reachable D2 is meaningful
and can suppress every pixel. Let I=inner2 and O=outer2:

| Condition | Output alpha / error |
|---|---|
| O<I | RGBA zero; m_error=1 |
| O=I | alpha255 iff D2>I, otherwise0; no error |
| O>I and D2<=I | alpha0 |
| O>I and D2>=O | alpha255 |
| I<D2<O | alpha=RNE(255*(D2-I)/(O-I)) |

RNE means nearest integer, with an exact half choosing the even integer. No
distance square root, floating point or approximate reciprocal is used.

For green screen (`s_blue=0`), excess=max(0,G-max(R,B)); for blue screen,
excess=max(0,B-max(R,G)). Correction=nearest(excess*s_strength/255), with
strength0..255. Only the selected screen channel is reduced by correction;
the other two channels are preserved. Correction<=excess, so no subtraction
underflow or saturation occurs. Strength0 is identity and255 removes the
entire excess. An actual green object can also be modified by this documented
rule; there is no foreground semantic classifier or hidden matte gate.

Each corrected color byte C becomes nearest(C*alpha/255). Output packing is
`{R8,G8,B8,A8}`, **premultiplied**, and every output color byte is <=alpha.
The denominator255 is odd, so these byte divisions have no half ties. This is
an integer opponent-distance variant, not FFmpeg/OBS equivalence, neighborhood
edge filtering, unpremultiplication or a complete chroma-key editor.

## Interface, ownership and reset

One clock, synchronous active-high rst, ordinary ready/valid, no CE or CDC.
Input acceptance is `s_valid && s_ready` on a rising edge with rst low. All
input fields, including every runtime configuration value, are sampled at
that event. Producers hold the entire token while stalled. Configuration can
change on every accepted pixel without affecting earlier pixels.

`s_x/s_y` are opaque unsigned16 coordinates, TAG_W is1..32 (default8), and
`s_user` is opaque32. SOF/EOL/LAST are opaque per-pixel flags: the core forwards
them and does not check frame length, marker syntax or coordinate order. It
does not generate missing-tail timeouts or imply a frame-safe control bank.

Every accepted input yields one ordered result unless reset cancels it.
`m_error` means exactly O<I; an error token retains all metadata and produces
zero RGBA. Output valid and every output field remain stable during
`m_valid && !m_ready`. Fields outside valid are unspecified. `pipeline_busy`
is the OR of all15 valid stages. No command-completion interface is implied.

Reset masks public ready/valid/busy low immediately; its rising edge clears
the valid pipeline and cancels all unretired tokens. Arithmetic registers need
no reset because their values cannot become valid without a newly accepted
token. Already consumed results remain consumed. Peers must share the reset
epoch when using the supplied example.

## Actual source-over example

`example/screen_matte_over.sv` instantiates the new core and the unchanged
canonical `../rgba_porter_duff/rtl/rgba_porter_duff.sv`, with production mode3
(source-over). TAG_W is1..28 (default8); four extra production tag bits carry
configuration error and SOF/EOL/LAST. The public tag is never truncated within
that legal range. The example has no host-side matte or replacement blend.

The foreground s stream and background d stream rendezvous atomically. Each
accepts only when the other is valid and the matte pipeline can accept. Sources
must assert valid independently of ready and hold their pending tokens. The
caller supplies the corresponding background pixel; there is no address fetch
or coordinate matcher. After the joint acceptance, the background travels in
the matte core's user32 payload and can be released by the producer. It meets
the exact corresponding matte at the production blend input despite stalls.

Every accepted pair owns one ordered public result until that result retires
or reset cancels it. A matte output entering the blend is not yet a publicly
completed pixel. `pipeline_busy` covers both pipelines. There is no frame
completion response or rollback of an already delivered output prefix.

Background d_rgba is premultiplied `{R,G,B,A}`. Error bits are independent:
bit2 is invalid matte window O<I; bits1:0 are the original production error
code (0 legal,1 invalid mode,2 bad source,3 bad destination). Error codes1 and2
are unreachable for known legal inputs because mode is constant and
the matte always produces premultiplied paint, including zero on error. A bad
background yields3; a simultaneous invalid window and bad background yields7.
Any matte error forces the final public RGBA to zero; production blend errors
also produce zero through the original core. Coordinates/tag/flags survive.
An invalid window still consumes exactly one paired background and produces
exactly one result; it is not a dropped stream token.

The source-derived total is18 stages and capacity18 paired tokens. With no
stalls, a pair accepted at edge0 becomes output-valid after edge17 and first
transfers at edge18; dense service has II=1. Downstream stalls and unmatched
input arrival add latency. Reset masks both public input readies/output valid
and clears both pipelines at its rising edge. No canonical source is edited.

## Architecture and source-level budget

There are15 globally stalled stages: opponent magnitudes/excess capture;
two squares and spill product; distance sum and channel correction; threshold
classification/numerator setup; eight quotient-bit stages; exact ratio RNE;
three premultiply products; final /255 byte quantization. A blocked final
output freezes all payload, configuration-derived state and metadata.

With no stalls, an input accepted at edge0 becomes output-valid after edge14
and first transfers at edge15. Dense input/output has II=1. Backpressure can
add unbounded delay; these are source-derived clock counts, not measured MHz
or a continuous camera/display throughput guarantee.

Six logical multiplications are explicit: two9x9 squares, one8x8 suppression
product and three8x8 premultiply products. The divider is eight unrolled
27-bit remainder compare/subtract stages with19-bit denominators, eight-bit
quotients and final exact remainder rounding. Its logic/register cost is
real. The source contains roughly2.4k scalar/pipeline register bits at TAG_W8,
including metadata; add15 bits for each additional tag bit. There is no
pixel/line/frame RAM or external-memory interface. Pipeline arrays describe
fixed shift registers, not additional memory ports.

The actual example adds the original blend's three stages, eight logical8x8
product expressions, four17-bit sums and quantizers, plus its x/y/tag/error
state. Its fixed source-over factors may allow constant simplification in a
future mapping; this document does not assume that result or a DSP count.

Mapping, physical DSP count, LUT/FF packing, resource fit, Fmax, power,
synthesis, PnR, STA and board behavior remain unmeasured. A logical multiply
does not establish one physical DSP. See SOURCES.md for semantic and license
review and VERIFY_PLAN.md for the proposed finite checks. Resolve files.f and
example/files.f from **this package directory**; preserve the sibling canonical
dependency path when copying the offline source tree.
