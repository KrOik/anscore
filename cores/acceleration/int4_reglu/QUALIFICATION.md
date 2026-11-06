# Finite B38 qualification

Receipt: reports/20261106T050649132695Z/results.json, SHA256
`de4cc22c0500974a7f2d00a92cc486b605ab977b99ea32ff42c217355a7f5888`.
Approved FINITE_PLAN.json SHA256
`e365eaeb9ada19d3b137ae7b7da9ff2b9d8a240af401620d44f532e6d57fa07e`.

A independently reviewed original arithmetic, source ownership, prefix bridge,
oracle, TB scheduling and frozen finite plan and closed NO_BLOCKER_A before
HDL. One explicit --execute-approved-plan invocation executed exactly 11
children: default/maximum/example syntax and four compile/sim pairs. All passed;
no historical failure, timeout, retry, changed RTL or repaired fixture. Each
child had a 20-second deadline and 7-second bounded cleanup; no cleanup timeout
path was needed. Durable INCOMPLETE/checkpoint receipts precede each child and
the runner refuses any existing reports entry.

| H/C/T, example | Retired outputs | Raw samples | Config handshakes | Command handshakes | Held-output clocks | Resets incl initial |
|---|---:|---:|---:|---:|---:|---:|
| 1/1/1, core | 38 | 24 | 93 | 44 | 176 | 8 |
| 3/9/8, core | 57 | 106 | 143 | 47 | 262 | 8 |
| 32/256/32, core | 202 | 1588 | 4929 | 47 | 914 | 8 |
| 4/16/8, actual signed32 prefix | 91 | 261 | 164 | 56 | 415 | 9 |

Totals: 303 ordinary vector comparisons, 77 error markers, plus 8 ordinary
results from four actual future-offer flows; 388 retired outputs, 1979 raw
samples, 5329 configuration and 194 command handshakes, 1767 held clocks and
29 live plus 4 initial resets. Each future flow keeps an unaccepted command
offered through a held configuration reply, then keeps configuration offered
through a held result. Its two results and the following vector query verify
the new output metadata took effect at the proper ownership boundary.

Numerical cases include signed4 minimum/maximum/random packing, gate/value
signs and ReLU closure, signed32 bias extremes, branch and output saturation,
scale0/65535, shift0/31, exact positive/negative half ties with an odd zero added
after rounding, asymmetric x_zero0/128/255, partial last words, maximum geometry,
runtime short vectors, persistent reconfiguration, missing output/branch
configuration, invalid indexes/words/opcodes/geometries, early/missing LAST and
invalidation. The actual prefix includes signed32 extremes and independently
compared input clip/inexact accumulation.

Reset scenes cover held configuration, local/child prechecks, query collection,
child MAC, registered post-scale, held output, plus the actual occupied prefix
slot. The latter asserts pending immediately before reset, without allowing a
leading extra clock that could consume it. One such reset was observed.

The executed ten current/archive source pairs, four independent integer vector
files, approved plan, 22 raw stdout/stderr streams and both tools retained
identical hashes. Source/plan/vector/tool/sequence guards all passed. Warnings
are limited to absent timescale declarations in delay-free production modules;
raw diagnostics remain intact. Source lists include unchanged committed
dependencies and are usable offline from the package working directory.

Numerical planning previews are distinct from the four generation calls used
to write the executed archived vectors. These are Python arithmetic only, not
additional HDL profiles. No synthesis/PnR/STA/board/PPA, combined compile,
inherited regression, whole-network inference or model accuracy check ran.
Hardware remains unverified.
