# Known-phase tone fit

Fits one signed16 sample window to a supplied sinusoidal reference phase while
eliminating an unknown constant offset and finite-window cross terms. The
reference phase travels on the same accepted beat as the sample. This is useful
for short, noncoherent, externally gated measurements where ordinary boxcar I/Q
projection is biased by a nonorthogonal reference window.

The unchanged `stream_sincos` and `img_hist_serial_multiply` are instantiated once
each. The fit uses their quantized basis and exact integer sufficient statistics.
There is no divider, sample RAM, frequency estimator, or amplitude/phase unit.

Use `files.f` from this package directory for the core, or `example/files.f` for
the actual `gated_tone_measure` adapter. The adapter connects the complete public
interface to one core and preserves its ownership and backpressure semantics.
It is a structural integration example; it does not add a reference generator,
input buffering, or throughput capability.

Read [CONTRACT.md](CONTRACT.md), [WIDTH_PROOF.md](WIDTH_PROOF.md), and
[ARCHITECTURE.md](ARCHITECTURE.md) before integration. Output I/Q is a signed128
numerator over one unsigned112 denominator; callers perform any desired division.
Positive denominator alone does not guarantee good conditioning.

The package is prepared for finite, separately gated functional qualification.
No execution result, device fit, timing, power, board result, or historical
regression is claimed by the source. The source-only plan is documented in
[FINITE_PLAN_DRAFT.md](FINITE_PLAN_DRAFT.md); execution requires the exact plan,
source seal, and root plus peer review to agree. Failed attempts and original raw
evidence must be retained, with no automatic retry.

License: Apache-2.0. See [SOURCES.md](SOURCES.md) for reuse pins and scope.
