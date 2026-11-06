# Premultiplied RGBA Porter–Duff composition

`rgba_porter_duff` composes a paired source and destination with independently retained alpha coverage. It supports transparent intermediate groups, masks and re-composable layers. For example premultiplied `(128,0,0,128)` over `(0,0,128,128)` gives `(128,0,64,192)`.

The existing fragment/sprite stores blend straight source RGB into an implicit opaque RGB target. The legacy OSD/sprite operators interpolate bytes independently. Those operations cannot preserve a partially covered destination or implement the full coefficient operators here. `img_mf_pair_join` only pairs streams. B41 source selection checked actual canonical and legacy implementations, not only names.

## Interface

All modules use one clock, synchronous active-high `rst`, ordinary ready/valid, no CE or CDC. A transfer occurs on a rising edge with `valid && ready && !rst`. Reset flushes all in-flight payload and held responses; samplers become nonresident. A source must hold its entire payload while valid and not ready. Output payload, mode, coordinates, tag and error remain stable while held. There are no implicit frame boundaries: x/y are opaque metadata, and no frame markers are generated.

Core inputs `s_src/s_dst` are unsigned `{R,G,B,A}` bytes, **premultiplied**: every color byte must be at most alpha. Modes and all metadata are sampled per accepted token, with no global configuration. `TAG_W=1..32`; x/y are 16-bit. Output has the same packing. Every accepted token produces one ordered output unless reset flushes it. Error priority is opcode > source > destination:

| `m_error` | Meaning | RGBA output |
| --- | --- | --- |
| 0 | Legal token | Calculated result |
| 1 | Mode 13..15 | Zero |
| 2 | A source color byte exceeds source alpha | Zero |
| 3 | A destination color byte exceeds destination alpha | Zero |

Error tokens retain mode/x/y/tag. Even clear/source/destination modes validate both complete inputs. Unknown four-state values are outside the functional input contract.

## Exact arithmetic

For every component, **including alpha**, `T = S*Fa + D*Fb` and `O = min(255, floor((T+127)/255))`. Factors are integers in units of 255. There are no half ties for denominator 255.

| Mode | Operation | Fa | Fb |
| --- | --- | --- | --- |
| 0 | clear | 0 | 0 |
| 1 | source | 255 | 0 |
| 2 | destination | 0 | 255 |
| 3 | source-over | 255 | 255-As |
| 4 | destination-over | 255-Ad | 255 |
| 5 | source-in | Ad | 0 |
| 6 | destination-in | 0 | As |
| 7 | source-out | 255-Ad | 0 |
| 8 | destination-out | 0 | 255-As |
| 9 | source-atop | Ad | 255-As |
| 10 | destination-atop | 255-Ad | As |
| 11 | xor | 255-Ad | 255-As |
| 12 | plus/lighter, clamped | 255 | 255 |

Eight 8x8 products are registered, four sums use 17 bits (`T<=130050`). If `T>=65025`, output is 255. Otherwise `t=T+127<=65151` and the exact bounded quotient is `(t+1+(t>>8))>>8`. The implementation never truncates a 17-bit plus numerator into a 16-bit blend helper. Common nonnegative factors and monotone rounding/saturation preserve `C<=A` after quantization.

The core has three global-stall pipeline stages: products, sums, quantization. With an always-ready sink its first token becomes visible after the third accepting edge, and a dense burst has II=1. A blocked output freezes all three stages; bubbles still advance when the output can advance. `pipeline_busy` reports any valid stage. These are RTL cycle properties, not measured MHz or board throughput.

## Actual dual-sampler example

`example/dual_indexed_porter_duff.sv` instantiates **two unchanged** resident `indexed_texture_sampler` modules, a two-stage atomic pair premultiplier, and the core. Compile from this package directory with `-f example/files.f`. The wrapper's `TAG_W=1..28` leaves four bits of the old sampler's bounded tag for per-query mode. Dimensions are 1..256 in each axis, default 8x8.

Management is bank-selected. `c_op=0` begins/restarts loading; `c_op=1` commits exactly `W*H` index bytes and 256 palette entries; other commands and incomplete commits return the unchanged sampler's status codes. `load_bank` selects the bank for both independent index and palette loading channels. Management palette `p_argb` is the old **{A,R,G,B}** packing. Each load channel and command obeys ordinary RV. `r_bank/status/tag/tex_count/pal_count` is held until accepted; only one management response is owned at a time.

Each public query carries separate source/destination u/v, shared x/y/tag and mode. Both sampler queries are accepted atomically; both responses are consumed atomically. Alpha-zero and out-of-range valid samples are retained (out-of-range is transparent zero), since mask/destination modes can still require an output. Sampler `visible/reason` does not suppress tokens. The adapter computes each straight color as `floor((C*A+127)/255)`, retains alpha, and explicitly remaps the palette packing. This conversion is an additional quantization boundary.

An owned-token count extends from query acceptance through final output acceptance. A pending `c_valid` blocks new queries immediately, but is not forwarded to either sampler until **all** sampler, conversion and composition stages drain. Thus management cannot deadlock a previously owned query. A held final output prevents management; the count is not decremented merely when arithmetic finishes. Index/palette writes are also gated until completely drained. No new query is admitted while a management response is held. A reset invalidates both residents and clears ownership.

The source-derived capacity is eight paired tokens (3 lookup + 2 conversion + 3 composition stages). Nominal first visibility is eight accepting edges with no stalls, and dense steady bursts can have II=1. Backpressure and management gaps add latency. There is no external framebuffer, output store, blend-space/color-management conversion, gamma correction, straight-alpha output division or hardware timing claim.

## Delivery and validation boundary

New code is Apache-2.0. Public coefficient semantics were checked read-only against pinned official Skia sources and BSD-3-Clause license; no Skia source is copied, translated, imported or executed. No bit-exact floating Skia equivalence is claimed. See `SOURCES.md`, `references.json` and `ARCHITECTURE.md`.

This README is a frozen **pre-execution specification**: source/model/TBs/runner and a finite plan must pass independent B review and receive explicit root authorization before oracle import/preparation or HDL execution. Final evidence and maturity are recorded separately in `STATUS.md`, `QUALIFICATION.json`, and `B41_DELIVERY.json`; a missing receipt means NOT_RUN. No synthesis, PnR, STA, board check or inherited/combined regression is part of this package.
