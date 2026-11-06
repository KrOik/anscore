# Exact coordinate-projected multistop linear gradient

`multistop_linear_gradient` produces premultiplied RGBA paint from actual
two-dimensional Q coordinates, runtime gradient endpoints and an ordered stop
table. It computes `t=dot(p-p0,d)/dot(d,d)` itself. It never asks the host to
calculate sample t, choose a stop interval or prepare output colors. The actual
example composes every paint result with unchanged `rgba_porter_duff`.

Baseline: `05b9614c3962e9d4ae934c4b9c7bd315cc01aed4`.
Original Apache-2.0. **RTL_CANDIDATE / SOURCE_ONLY / NOT_RUN / HW_UNVERIFIED**.
No numerical preparation, model, HDL, synthesis, PnR, STA, board, PPA or historical
regression has executed. The fixed finite plan requires root and independent
peer full-source review and a separately issued exact-hash execution gate.

## Coordinates, color and exact arithmetic

All endpoint and sample coordinates are signed18 two's-complement Q10.8,
including the sign in the10 integer bits: -512 through511+255/256. They use the
same coordinate system. For example an integer pixel centre is `(256*x+128,
256*y+128)` on the input wires. Sample coordinates are independent from opaque
unsigned16 destination x/y metadata, which is forwarded unchanged.

`d=p1-p0`, `D=dx*dx+dy*dy`, `N=(px-x0)*dx+(py-y0)*dy`, all exact integers.
The common coordinate scale cancels in N/D. No reciprocal approximation or
intermediate t rounding occurs. Spread mode0 PAD clamps t to[0,1], mode1 REPEAT
uses `t-floor(t)`, mode2 REFLECT reduces modulo2 then reflects the second unit
interval. Negative coordinates use Euclidean modulo, not signed truncation.
REPEAT maps every exact integer to0; REFLECT maps even integers to0 and odd
integers to1, including negative integers. PAD includes both endpoints.

Stop offsets are unsigned17 with denominator65536; only0..65536 is legal.
Every stop color is premultiplied `{R8,G8,B8,A8}`, with each RGB byte<=A.
The bytes have a caller-defined common color space. No gamma, transfer-function
conversion, unpremultiplication or hidden straight-alpha conversion is performed.
Interpolation is linear in those supplied premultiplied components. Stop colors
can be supplied in sRGB byte space, but that is not linear-light interpolation.

Offsets must be nondecreasing. Duplicate offsets are legal hard transitions:
the last stop at an exact offset supplies that point's color. The first member
of the next duplicate group supplies the color approached from below. Before
the first stop use the first color; after the last use the last color. One stop
is a constant gradient. With coincident endpoints, every spread returns the
last stop and sets `m_degenerate=1`; no division by zero occurs.

Configuration caches `T_i=D*offset_i`. After spread, let exact projected
fraction be `r/D`. Compare `r*65536` directly with these thresholds. For left
and right thresholds L<R, each byte is exactly

```
RNE((C_left*(R-r*65536) + C_right*(r*65536-L))/(R-L))
```

RNE means nearest with ties to even, using the complete integer remainder.
Only this final byte result is rounded. Convexity and monotone RNE ensure RGB<=A
also after output rounding. A color at a stop or outside the stop range is
returned exactly, without an unnecessary rounding step. See ARCHITECTURE.md
for complete bit bounds and why no legal intermediate is truncated.

## Management, loading and publication

One clock, synchronous active-high reset, ordinary valid/ready, no CE or CDC.
Reset must span a rising edge. It masks public valid/ready/configured/loading/
busy immediately, cancels ownership/responses and invalidates the complete
gradient epoch. Payload RAM is not reset and cannot be read until a new full
load is published. Internal reused CE interfaces are tied enabled; do not
connect a CE-qualified external stream without an adapter.

| Channel | Meaning |
|---|---|
| c_valid/c_ready | Management c_op2, c_count32, c_spread2, signed endpoint coordinates, opaque c_tag |
| r_valid/r_ready | One held management response: r_status3, r_count32 accepted-and-committed stops, echoed r_tag |
| t_valid/t_ready | Sequential stop load: t_offset17 and premultiplied t_rgba32 |
| s_valid/s_ready | Actual sample s_px/s_py, destination s_x/s_y16, opaque s_tag |
| m_valid/m_ready | One held m_rgba32, destination coordinates/tag and m_degenerate |

MAX_STOPS1..16 defaults16; TAG_W1..32 defaults8. Unsupported parameters fail
elaboration. c_op0 BEGIN always invalidates the old resident table immediately,
then validates count and spread. A valid BEGIN computes D from its saved
endpoints and returns success before enabling stop loading. Exactly c_count
stops must transfer. Each stop's threshold and color are committed in synchronous
RAM before the accepted count increases. Full loaders backpressure extra stops.

c_op1 PUBLISH succeeds only after all stops have committed and every stop is
valid. Premature publication returns INCOMPLETE, preserving the partial load.
A malformed offset/order/color sets a sticky load error, but all advertised
stops can still drain; publication returns BAD_STOP. Such a load cannot become
resident and needs a new BEGIN. No truncated-input timeout is supplied.
c_op2 INVALIDATE discards resident/load ownership and counts. c_op3 is BAD_OP
and preserves the current mode/table/counts. Geometry changes require BEGIN
and a complete resend of stops: original offsets are not retained in RAM.

Status0 OK,1 INCOMPLETE,2 BAD_COUNT,3 BAD_SPREAD,4 BAD_STOP,5 NOT_LOADING,
6 BAD_OP. BEGIN count validation precedes spread validation. Bad BEGIN returns
count0 and leaves neither a resident nor a load. INVALIDATE returns count0.
Other responses report the committed count at command acceptance.

Management offers have priority at idle. A management command is admitted only
after current sample/result or stop write drains. Its held response blocks all
input streams. An accepted sample owns the service until its held output retires;
new management cannot alter it. There is no same-edge retirement/admission
fallthrough. Sources retain valid and all fields until handshake or reset.
All outputs remain stable under unbounded backpressure. Continuously offered
management can starve samples; upstream arbitration owns inter-client fairness.

## Actual composition and service scope

`example/linear_gradient_porter_duff.sv` instantiates this core and unchanged
`rgba_porter_duff`. It accepts real sample coordinates, premultiplied destination
and mode0..12, saves destination/mode on acceptance, and retains a single owner
through the final composed output. A pending management offer cannot block an
already accepted paint/composition. Its mode/error semantics are unchanged:
bad mode returns error1/zero; malformed destination returns error3/zero, with
mode-error priority. Paint is always valid premultiplied data, so source-error2
cannot occur. Transparent paint still performs composition; destination-saving
operators can return nonzero pixels. No fragment is silently dropped.

The interface serves sparse coordinates or a dense row-major caller stream.
The finite TB supplies a complete7x5 pixel-centre grid as well as sparse samples;
the example contains no hidden image, host-prepared t or pre-rendered table.
There is no triangle/rectangle coverage generator, framebuffer, antialiasing,
display timing, full SVG/CSS parser, transform stack or frame deadline.

One53x18 serial shift/add multiplier, one61-bit iterative divider and one
88*MAX_STOPS synchronous RAM are reused across all work. Stops cache only
53-bit thresholds+32-bit colors+3padding bits:1408 logical bits at16 stops.
Two multiplications prepare geometry once, one prepares each loaded stop; a
query uses two dot products, at most one modulo division, sequential stop reads,
and at most eight color products plus four divisions. This deliberately trades
latency for bounded storage and one arithmetic owner. No synthesized DSP/LUT/
FF/RAM inference, MHz, power or display throughput is claimed.

FINITE_PLAN.json proposes five separate archived preparations before any HDL:
core MAX_STOPS/TAG1/1,5/8,16/32 and actual blend5/8,16/32. Each scores15 gradient
configurations and635 outputs, including35 dense-grid samples, all spread modes,
exact negative boundaries, tiny/extreme vectors, duplicate stops, full stop
capacity and degenerate vectors. Every main output is held4 cycles. Management
errors, partial publish/resume, legal pending next-query/management offers and
8 live reset/reload/recovery fixtures per profile are checked separately.

The once runner must archive exact input/control bytes and pin all tools before
preparation. It imports no project model. Simulation image SHA and prechecked
flag are fsynced in an exclusive immutable initial sidecar before Popen. Every
child has20seconds, tree helper5seconds and one sole2second exit observation.
Any failure stops all subsequent children, retains raw evidence/images and
does not retry or delete anything. No unrun check is PASS.
