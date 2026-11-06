# B39 finite qualification

Result: LINT_PASS, UNIT_SIM_PASS, INTEGRATION_CANDIDATE, HW_UNVERIFIED.
The pre-execution candidate status in README is superseded by this executed
qualification. No frozen executable source changed after review or execution.

Baseline: `1e9e9130cef71127d2c8d2762affe815b067b9f5`.
C completed a full source-only review of RTL, actual wrapper, both TBs,
independent model, runner/plan and both unchanged dependencies. Root completed
the final review and authorized only the fixed11-child execution. Reviewed plan
before changing its review field:
`f341e1534daac04fe1b89ea37c4568c0f9c2f89badadd7788e717730b3f7d019`.

Final executed plan:
`50a97f7d035dcf1139d39f22b2feefece6c3352e373e49cbbcdafdee02d9f7ea`.
Receipt: `reports/20261106T060139059935Z/results.json`, SHA256
`94178b7a015a548d56018572432e6728e799e1ee14bd508c88fe580e224ba534`.

All11 children passed on the first execution:3 syntax,3 core compile/sim pairs
and1 actual receiver/request example compile/sim pair. Every child had a20-second
limit and process-tree cleanup5 seconds plus drain2 seconds. No child failed or
timed out. There were no retries, automatic repairs, matrix extensions or
successful-profile reruns. Three oracle vector-generation calls occurred after
the exact10-source dependency archive and plan archive; all vector bytes were
frozen before the first HDL child. Hash-only plan writes made no oracle calls.

| Core profile CONTEXTS / REQUEST_MAX / TAG_W | Checked responses | Held clocks | Actual future GETs | Resets | Request emissions |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 / 1 / 1 | 532 | 3192 | 266 | 7 | 9 |
| 5 / 7 / 8 | 788 | 4728 | 394 | 7 | 37 |
| 32 / 65534 / 32 | 2516 | 15096 | 1258 | 7 | 226 |
| Total | 3836 | 23016 | 1918 | 21 | 272 |

Each actual future GET remains valid through admission, checks an independently
generated snapshot, stalls6 clocks and retires. Across the three simulations,
21 resets comprise3 initial and18 live resets. Live coverage includes vector
state invalidation and the explicit pre-RAM, accepted-write/pre-commit and held
result phases. Core first-valid latency stays within5 clocks in every tested
command, including maximum and non-power-of-two context profiles.

The actual example passed8 accepted configs (one aborted),15 completely
submitted binary packets,5 accepted retries (one aborted),6 complete20-byte
requests plus19 retired bytes of a reset-aborted request (139 request bytes),
1 retired normalized Add Order,24 checked completions,131 held/blocked clocks
and6 resets. It covers whole future/overlap rejection, duplicate suppression,
original-descriptor retry, partial-progress continuation, heartbeat extension,
EOF/reconfiguration, uint64 overflow, full event/request/response ownership and
five live reset phases.

Four TB compile children report only that production modules omit explicit
simulation time units. All3 syntax and4 simulation stderr files are empty.
No unsupported-construct, width, syntax or functional diagnostics were emitted.

`EVIDENCE_AUDIT.json` records a separate standard-library audit without importing
or calling the model/runner, and without further HDL. It verifies37 persisted
raw/archive/plan/vector/receipt artifacts,10 current-to-archive source mappings,
both executable hashes, all11 exact argv/cwd/limit specifications, vector record
counts and packed result widths, exact raw markers/counters, and4 compiled image
hashes. Compiled images remain task-local until root's bounded cleanup; they are
not formal Git artifacts. All raw logs, vectors and executed source copies are
retained for review.

No synthesis, placement/routing, STA, board or legacy regression was performed.
No frequency, resource, power or reliable-delivery claim is made. The example
does not buffer/reorder future payloads or implement IP/UDP transmission and
timers. The existing strict receiver's accepted-EOF epoch policy remains the
documented composition boundary. This qualification applies only to the sealed
sources and finite profiles, not arbitrary parameter/protocol/network scenarios.
