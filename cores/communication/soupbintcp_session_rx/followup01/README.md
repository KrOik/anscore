# SoupBinTCP declaration-order followup01 (source only)

The initial attempt is retained at `../reports/20261106T131548185120Z`.
Its one preparation passed (one oracle import and one numerical preparation).
The first syntax child exited 2 because `start_error` was referenced before its
reg declaration with `default_nettype none`. No other HDL child or simulation ran.
Every original source, file list, plan, seal, review, guard, vector, raw stream and
receipt remains unchanged and is hash-bound by this independent followup.

Use `followup01/files.f` as the recommended executable source list. The canonical
module/top name remains `soupbintcp_session_rx`; there is no alias or wrapper.
The original `../rtl/soupbintcp_session_rx.sv` and `../files.f` are historical failed
inputs and are not this corrected execution entry. Do not compile both core copies.
The corrected RTL differs only by moving the existing `start_error` declaration
above its first use. All original protocol logic, FIFO, oracle and TB bytes remain.
The private FIFO and the original TB are referenced directly by the new file list
and commands; the original core is retained as evidence, not compiled.

This new finite plan has zero preparations/model calls and exactly nine HDL
children: three syntax checks and three compile/simulation pairs at D32/T1,
D128/T8 and D4096/T32. It reuses the original three vector files at their exact
original paths and SHA256 values. No vectors are regenerated. All compiled images
are retained at their initial followup `.work` paths. Each child has a 20-second
target budget, one <=5-second tree helper, a nonwaiting direct target-kill fallback,
and the sole <=2-second target exit observation. Raw bytes/PID/exit evidence is
persisted before parsing; complete frozen inputs and previous evidence are checked
before every launch. Failure stops immediately with no retry or cleanup.

`SOURCE_SEAL.json`, `FINITE_PLAN.json`, an independent root/peer
`SOURCE_REVIEW.json` and the unique `B45_SOUP_SESSION_RX_FOLLOWUP01_ONCE` gate are
required before execution. This source package has not executed any model, HDL,
runner or preparation. Syntax/simulation/synthesis/PnR/STA/board/PPA remain NOT_RUN;
status is RTL_CANDIDATE / HW_UNVERIFIED. Licenses and provenance are in the retained
parent package; this original correction and runner remain Apache-2.0.
