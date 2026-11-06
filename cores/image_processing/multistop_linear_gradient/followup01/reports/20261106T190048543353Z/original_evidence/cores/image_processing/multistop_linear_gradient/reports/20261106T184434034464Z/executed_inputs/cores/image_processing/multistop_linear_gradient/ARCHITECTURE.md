# Numeric and architectural budget

Coordinates are raw signed18 with common2^-8 scale. A difference is signed19,
with absolute value at most262143 (2^18-1), representable in unsigned18.
The magnitude of a coordinate product is below2^36. The squared norm obeys
`0<=D<=2*(262143^2)<2^37`; a dot product obeys `abs(N)<2^37` and fits signed38.
RTL explicitly sign-extends coordinates before subtracting, computes unsigned
magnitudes, retains each36-bit product and extends to37/38 before summing.

Legal offset0..65536 multiplies D to at most D*65536<2^53. Spread produces
0<=r<=D, so r*65536 also fits53. The shared multiplier is53x18, full output71;
coordinates use18x18, cached thresholds37x17, colors53x8. Consumed slices are
respectively36,53,61 bits, justified by these complete-domain bounds, rather
than by the finite vectors. Invalid offsets may exceed the threshold domain;
their sticky-invalid load can never be published or read by a sample.

The selected interval has positive denominator R-L<=D*65536<2^53. Its two
nonnegative weights sum exactly to that denominator. Each channel numerator
therefore lies in0..255*(R-L)<2^61. The two61-bit products are added without
overflow under this invariant. A61-bit divider returns full quotient/remainder;
an explicit62-bit doubled remainder implements RNE. Legal quotient<=255, and
rounding cannot produce256: quotient255 implies exact numerator255*denominator.
RGB<=A before division and after monotone rounding. No saturation masks errors.

For repeat/reflect the same divider computes abs(N)/D, retaining quotient
parity and remainder. Repeat negates the residual geometrically: negative N
with nonzero remainder gives D-rem; exact negative integers give0. Reflect is
even in N, with odd quotient yielding D-rem and even quotient rem. This gives
the exact endpoints at both signs without signed integer division ambiguity.
For PAD direct signed comparisons avoid division. D=0 skips modulo and scans
the zero thresholds to the last stop. Equal thresholds are always consumed by
the `target>=threshold` branch, making the last equal stop win; interpolation
starts only at the first strictly greater threshold, preventing zero division.

Paper candidates considered: approximate reciprocal plus LUT ramp is smaller
per sample but changes exact boundaries/ties; parallel products/dividers buy
throughput with duplicated arithmetic and stop-table ports; the selected
single-owner exact design reuses existing sequential arithmetic. There is no
specified scanout-rate constraint that warrants a wide parallel renderer.

Storage is one unchanged cip_sync_sp_ram of88bits byMAX_STOPS, with exactly
one request and one drained reply per stop write/read. It stores `{3pad,
threshold53,premultipliedRGBA32}`. Original offsets are discarded after load;
new geometry invalidates the table and requires complete reloading. Scalar
registers, retained row/left/right colors and thresholds, and child arithmetic
registers are additional. The serial multiplier pads71 bits to72 for its carry
save and byte-fold schedule; it has18 CSA+9 fold iterations. The divider has61
iterations per division. A query performs at most10 products,5 divisions and
16 stop reads, serialized with explicit setup/retirement states. Source budget
is under700 no-stall clocks per core sample, plus composition/drain; this is
an unmeasured source estimate, not device timing or a tested latency contract.

Ready chains terminate at one owner. Output stalls cannot alter the RAM table,
saved geometry, query metadata or composition destination/mode. The example
extends the owner beyond the paint core's private retirement through held
Porter-Duff output. Pending management is withheld from the core during that
interval, so it cannot prevent internal completion. One genuine future query
and one pending management command are separately held through ownership by TB.

Resource risks: LOW logical table capacity; MEDIUM scalar wide arithmetic,
control and physical RAM packing; HIGH latency for dense frames. A serial
architecture is not measured lower power. There is no PPA, device-fit or
frequency evidence, and no synthesis/PnR/STA/board step is authorized here.
