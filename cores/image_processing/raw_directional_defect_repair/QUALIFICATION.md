# Qualification

The original one-shot finite suite completed **PASS** at
`reports/20261106T164623_121013Z/results.json`. Its SHA256 is
`0ef0bc81833490c87f7fe4c7037201672bdc70a56d412e7bfa1d0fad1bb46266`.

This is a later qualification record. The sealed README and manifest retain
their authoring-time EXECUTION_PENDING fields so that executed inputs remain
byte-for-byte unchanged. The terminal receipt is the result authority.

## Frozen execution identity

| Item | Binding |
| --- | --- |
| Baseline | `3a58c99bda6f6f62a34d1c20247d3b42d8d89006` |
| Gate | `B48_RAW_DIRECTIONAL_DEFECT_REPAIR_ONCE_01` |
| PRECHECK_PLAN.json SHA256 | `bd1c97a8eb498b5d9404704e9668c5897c01841345b92a27a74a15c8bff9953b` |
| SOURCE_SEAL.json SHA256 | `0d7eadc63bc870562e8b18ce29c4670277a1123280d13a9b0e0d7ba002c0066f` |
| run_checks.py SHA256 | `b002f6b5791aa80d7756f6d528d44af1547a21e098ad127cbc05fd5da29a6d38` |
| ROOT_REVIEW.json SHA256 | `8ff629385efc11502723d1b6294a78f1666b9a903a705b094b134215b10cef6b` |
| Pre-execution review | Root NO_BLOCKER; independent worker_b NO_BLOCKER |

The command sequence was eight direct archived-oracle preparations, two syntax
children, eight compile children and eight simulation children:26 total,
18 HDL children. Each used a 20-second child deadline, 5-second tree-termination
budget and one shared 2-second exit-observation budget. Every recorded child
returned zero with exit confirmed and complete captured output. No timeout,
cleanup attempt, capture error, retry or active child/helper remains.

## Observed finite coverage

| Profile | Dimensions | BITS / TAG_W | Cases | Pixel comparisons | Reset checks |
| --- | --- | --- | ---: | ---: | ---: |
| core_min | 1x1 | 8 / 1 | 16 | 16 | 3 |
| core_thin | 2x4 | 8 / 8 | 12 | 96 | 3 |
| core_five | 5x5 | 12 / 8 | 20 | 500 | 3 |
| core_small | 7x7 | 10 / 7 | 28 | 1372 | 3 |
| core_tall | 1x512 | 10 / 32 | 8 | 4096 | 3 |
| core_max | 256x256 | 12 / 32 | 2 | 131072 | 3 |
| bayer_small | 7x7 | 10 / 7 | 28 | 1372 | 3 |
| bayer_wide | 512x1 | 8 / 32 | 8 | 4096 | 3 |
| Total | | | **122** | **142620** | **24** |

The two Bayer profiles exercise the actual composition with the unchanged
production demosaic engine. The checks cover the complete output bundle and
repair summary, source gaps, held first/last output and DONE, ignored live
configuration changes, marker errors, reset cancellation and recovery.
Directed local fixtures exercise four directions and tie order, strict
threshold equality, half-up interpolation, full-width threshold overflow,
all gradient shifts, disable, border pass-through and all four public CFAs.
Coverage is finite; this table does not assert exhaustive parameter or input
coverage.

Each of eight preparation processes loaded the direct archived oracle once.
The runner imported no project oracle. Prepared vector headers, row counts,
hashes and counters agree with the simulation markers. All simulations reached
normal testbench finish with empty stderr.

## Retained evidence and author audit

The receipt retains 18 archived source/dependency files, three archived control
files, 26 terminal child records, 52 raw stdout/stderr streams and 16 vector/
preparation files:116 report files including the receipt. Eight compiled VVP
images remain in `.build/20261106T164623_121013Z/`.

[POST_AUTHOR_AUDIT.json](POST_AUTHOR_AUDIT.json) records the subsequent read-only
author audit: all 18 current source hashes equal the frozen and archived bytes,
all 24 tool entries match, all retained evidence hashes and sizes match, the
exact planned command order matches, and all eight image hashes agree with
compile and prechecked simulation bindings. The sealed runner and pre-execution
review establish the durable pre-Popen image-binding order; a separate initial
snapshot is not retained. The audit is an author self-check, not independent
post-execution review.

Independent worker_b post-audit is recorded in
[POST_PEER_AUDIT.json](POST_PEER_AUDIT.json), status PASS_NO_DISCREPANCY.
[POST_ROOT_AUDIT.json](POST_ROOT_AUDIT.json) records root PASS / NO_BLOCKER.
Both bind the same terminal receipt and confirm the retained evidence.
[QUALIFICATION.json](QUALIFICATION.json) provides the structured qualification.

Icarus emitted warnings about missing time units in reused modules and complete
array sensitivity in the local combinational selector. The ten syntax/compile
stderr streams match the two reviewed warning payloads; they are retained
unmodified. There were no simulation stderr messages.

## Qualification boundary

Status is finite functional simulation PASS and **HW_UNVERIFIED**. No synthesis,
place and route, static timing, board run, measured resource/power/frequency
result or remote publication was performed. Local accepted-window II=1 and
logical line-storage arithmetic remain source-level architecture statements;
the inherited row-window service and external stalls determine complete frame
timing. No photographic-quality, clustered-defect, calibrated noise-model or
vendor-equivalence claim follows from these fixtures.

