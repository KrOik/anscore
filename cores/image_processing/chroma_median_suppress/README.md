# Luma-gated chroma median suppression

`chroma_median_suppress` removes local chroma outliers from a same-resolution
unsigned YCbCr444 raster. The center Y code always survives exactly. Two
independent original-neighborhood medians replace Cb/Cr only where the local
Y range passes a frame-latched threshold. This targets color speckles and
false-color cleanup after demosaic without filtering the Y plane.

Status: **LINT_PASS / UNIT_SIM_PASS / INTEGRATION_CANDIDATE / HW_UNVERIFIED**.
The root-authorized first finite run passed11/11 children and4/4 simulations,
with one oracle import/preparation, no failure, timeout, cleanup or retry.
Synthesis, PnR, STA, board and old regression remain NOT_RUN.

For an interior coordinate `(x,y)`, let `P` be its nine ORIGINAL 3x3 pixels:

```
range = max(P.Y) - min(P.Y)
apply = enable && interior && range <= luma_threshold
out.Y = center.Y
out.Cb = apply ? sorted(P.Cb)[4] : center.Cb
out.Cr = apply ? sorted(P.Cr)[4] : center.Cr
changed = (out != center)
```

The complete one-pixel border and all thin images bypass. The two chroma
medians need not come from the same original pixel. There is no iterative
feedback: corrected outputs never become donors. No averaging, scaling,
subsampling, coefficient quantization or signed chroma interpretation occurs
inside this core. `applied` denotes the gate predicate, even when both medians
equal their center values; `changed` denotes an actual code change. The range
and threshold are unsigned BITS-bit codes with exact equality accepted. The
gate protects Y edges; it does not prove a scene has no genuine chroma edge.
This is a specified integer filter, without a universal perceptual improvement
or moire-removal claim.

All ports share one rising-edge clock. `rst` is synchronous active high,
overrides every phase and cancels in-flight work, held output and DONE. There
is no CE, CDC, automatic timeout or external memory interface. Ordinary
ready/valid transfer is `!rst && valid && ready`; the source holds its payload
while blocked. Reset does not clear row payload RAM. New complete line capture
and padding establish every valid neighborhood before it can be consumed.

Parameters WIDTH/HEIGHT are each1..512, area at most65536, BITS8 or10 and
TAG_W1..32; defaults64x48/BITS8/TAG8. Invalid static parameters are unsupported
and raise `$fatal`.

| Port | Contract |
| --- | --- |
| `c_valid,c_ready` | START only when idle and no held DONE. Snapshot enable, BITS-bit luma threshold and tag; later command-pin changes do not affect that frame. |
| `s_data[3*BITS-1:0]` | Exactly N raster pixels, packed `{Y,Cb,Cr}`. Full unsigned channel range is legal; caller owns color standard/range. |
| `s_sof,s_eol,s_last` | Required at pixel0, each last column and pixelN-1 respectively, zero elsewhere. Bad accepted markers set DONE bit0; processing continues for fixedN, feeding canonical markers to the reused windows. |
| `m_data,m_valid,m_ready` | Same N raster positions. Payload, regenerated SOF/EOL/LAST and applied/changed remain stable while blocked. |
| `d_valid,d_ready` | Held DONE only after the final output transfers. New START remains blocked until DONE is acknowledged. |
| `d_error[1:0]` | bit0 malformed input markers; bit1 window/network alignment or dependency marker diagnostic. A bad frame's emitted pixels must be treated accordingly. |
| `d_applied,d_changed[16:0]` | Counts of retired pixels, each0..N; final DONE includes the last pixel. |
| `d_tag,busy` | Original START tag and ownership through held DONE. Tag is per-frame DONE metadata, not a per-pixel port. |

Missing input tokens or unbounded consumer stalls can wait forever. No next
frame overlaps the current one. Reset cannot retract an already consumed output
prefix. The two legacy median networks have identical valid state and global
stall conditions; one common ten-stage bypass/gate pipeline advances on that
same condition. Three identical windows receive and retire pixels atomically.

The actual `example/rgb_chroma_clean.sv` connects TWO unchanged `csc_stream`
instances around the new core, fixed to BT.601 full-range forward/inverse,
BITS8 or10. Both CSC configurations are accepted with START and commit on
their own first accepted SOF. The wrapper checks external markers, sends
canonical markers to the front CSC and counts actual intermediate transfers.
Public DONE waits for the core DONE AND final RGB output retirement. Wrapper
error bit2 reports CSC configuration errors; bits1:0 include core diagnostics
and external marker failure. Applied/changed count YCbCr-domain pixels.

The example's output is the exact existing Q16 CSC round/saturate composition;
even disabled filtering performs an RGB->YCbCr->RGB round trip and need not
return identical RGB codes. Core Y preservation does not imply exact RGB luma
after inverse CSC clipping. No gamma/transfer conversion, RGB bypass switch,
camera capture, scanout, hardware pixel-clock guarantee or full ISP is added.

`files.f` and `example/files.f` are package-root relative and include the exact
offline dependency closure, including `csc_coeffs.vh` through an explicit
include directory. Four shared RTL files are byte-identical to the B40 baseline.
The untouched coefficient include has working-tree CRLF versus repository LF;
its clean Git blob matches the baseline and its exact CRLF bytes are frozen.
See `ARCHITECTURE.md`, `SOURCES.md`, `PRECHECK_PLAN.json` and `STATUS.md`.

The finite receipt is `reports/20261106T063409208470Z/results.json`. It compares
15264 output records:32 minimum,2016 and7072 larger YCbCr pixel/flag records,
plus6144 RGB pixels in32 actual16x12 rasters. Across all profiles,136 STARTs
were accepted,128 DONE payloads checked and124 DONE handshakes occurred by
the TB schedule. Sixteen resets include four initial and twelve live resets;
eight commands reset before complete output, and four additional checked DONE
responses reset while held before retirement. Applied/changed counts total
7936/2384 and held-output cycles4292. Two frames per profile intentionally have
bad input markers and correctly return marker-error DONE. Four successful
simulations reached `$finish`, with empty simulation stderr; compile notices
only identify missing explicit timescale in unchanged dependencies. The longest
child took3.187 seconds under the fixed20-second limit.

The frozen pre-run plan remains unchanged. Its historical review-pending state
does not replace the executed receipt or independent `QUALIFICATION.json` and
`B40_DELIVERY.json`. All14 executable inputs and exact archives,20 frozen
vectors,22 raw streams and two tool binaries are independently hash checked.
No maximum-size traversal, height512 functional run, exhaustive parameter sweep,
image-quality guarantee, physical resource mapping or hardware video-rate
qualification is claimed. Root owns staging/commit and policy-permitted
cleanup; worker C retains the four successful VVP images and deletes nothing.
