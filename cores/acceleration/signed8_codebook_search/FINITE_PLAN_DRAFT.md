# Unexecuted finite qualification draft

Baseline:05b9614c3962e9d4ae934c4b9c7bd315cc01aed4. No project, model, AST,
compiler, simulator or launcher has executed for this package. This document
does not authorize execution and is not the final frozen plan.

Planned boundary cases: MAX_CODES/MAX_DIMS1/1,3/5,64/256, plus the actual
residual-encoding wrapper at16/16. The independent model sorts full Python
integer distances. Its deterministic vectors include invalid counts, missing
rows, rejected configuration addresses/order, equal codewords, full negative
and positive extremes, prefix shortening/republication, persistent reuse,
reset and fresh configuration, exact positive/negative residual255 and
nearest-even half ties. The final row is made a unique winner, and full vectors
at opposite signed8 extremes exercise the24-bit distance bound. All cases compare exact summary, reconstructed
component and residual; the wrapper additionally compares RNE/clip/inexact.

The unexecuted testbench includes deterministic input gaps, configuration/summary/replay
backpressure with stable payload assertions, changed live inputs, simultaneous
idle config/command priority, reset during held configuration reply, input
capture, shared arithmetic, held summary and held replay/encoded output.
It checks tags, dimensions/LAST, no stale result after reset, and recovery with
fresh prefixes. The wrapper also accepts a new query with a different shift
while the previous encoded result is held, then checks both tags and values.
Its HDL watchdog is bounded at1,500,000 clock edges.

Before any execution, freeze the final RTL/model/TB/filelist/runner/toolchain
closure and numerical preparation list. Obtain full root and independent
peer source review and exact final pin approval. Every child gets20 seconds,
tree termination helper5 seconds, and sole target exit observation2 seconds.
Persist an immutable initial simulation-image SHA and prechecked record with
fsync before Popen; preserve separate terminal records and raw streams.
Failure or timeout stops later children. No automatic retry. Preserve failed
inputs, controls, output and original images. No historical regression,
synthesis, placement/routing, STA, board tests or PPA is in scope.
