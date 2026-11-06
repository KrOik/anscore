# Independent post-run peer audit

Verdict: **PASS_NO_BLOCKER**, reviewer worker_c, read-only audit2026-11-06.

Bound results SHA256: a34ca8cc9fd3cef14c29df074a66120182cba9e225c2264e86de48806faf4061.

- Canonical and archived17 sources, all24 tool binaries, and all3 archived controls match reviewed pins. Exact archive closure retained.
- All14 commands match the sealed plan in order:4 isolated preparations,2 syntax,4 compile and4 simulation children. No project code was rerun.
- All14 child JSON records equal their embedded results records; all28 raw outputs,8 vector/receipt artifacts and4 VVP images match hashes and recorded byte sizes where provided. Compile and execution images are identical.
- Every child returned0, exited within20s, captured both streams completely, and has no active PID, timeout, capture error or cleanup invocation. The reviewed runner uses5s tree termination and one shared2s exit/drain interval. Those exception paths were not needed.
- Each simulation reports32 fixture cases,46 responses,184 held cycles,14 cancellations,14 fresh recoveries and continuous=1. Observed adjacent accepted clocks:581 /1386 /10115 /1386 for minimum/default/maximum/IQ. Each raw output contains normal $finish and empty simulation stderr.
- Four standalone numerical preparations and four oracle-definition loads are recorded; runner imports zero oracles. All preparations precede any HDL child.
- Suite completeness, immutable inputs, archived sources and exact-plan flags are confirmed. One original execution directory and one unique once gate remain. Compile warnings only concern missing explicit time units in existing design elements.
- No synthesis, PnR, STA, board or PPA result is claimed; hardware remains HW_UNVERIFIED.

Failures: 0. C subpixel_rect_coverage frozen inputs were not changed during this audit.
