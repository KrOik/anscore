# B36 finite qualification

The first and only execution of `python -B cores/storage/itch_order_state/run_checks.py`
from the repository root passed all 11 planned child processes. There was no
failed child, timeout, automatic retry or post-run executable edit. The receipt is
`reports/20261106T035057204435Z/results.json`, SHA256
`5317fafebfd6a0c6343fc29912ecb55a8288f67539b0a9c9f9436345a4a27cbe`.
Baseline is `8ba6835fe51ad285b926cd24e3ba4d172aefce26`.

## Executed checks

The runner used absolute repository-local OSS-suite Icarus/vvp executables,
recorded their SHA256 values, and imposed a 20-second hard deadline per child.
Its timeout path terminates the process tree and bounds subsequent cleanup.
First failure stops further launches; any existing receipt prevents automatic
retry. No child exceeded its deadline. Raw stdout/stderr, exact commands,
return codes, elapsed times and hashes remain in the receipt directory.

| Check | Result |
| --- | --- |
| Default core syntax | PASS |
| ORDERS64/TAG32 core syntax | PASS |
| Actual receiver/state example syntax | PASS |
| ORDERS1/TAG1 compile + simulation | PASS + PASS |
| ORDERS8/TAG8 compile + simulation | PASS + PASS |
| ORDERS64/TAG32 compile + simulation | PASS + PASS |
| Actual receiver/state example compile + simulation | PASS + PASS |

Compiler stderr contains inherited-timescale warnings for delay-free production
modules. Simulation stderr is empty. All four simulations publish their expected
PASS marker and reach `$finish` with return code zero.

## Observed finite coverage

The independent oracle is an ordinary Python dictionary of full 64-bit order IDs
and side/price/quantity records. It has no hash probing, tombstone or RTL state
machine implementation. All three ASCII fixtures were frozen and hashed before
the first HDL child. Each ordinary command checks every response bit and the
complete live map across both child tables against the oracle, requiring every
expected row to appear exactly once. This includes preserving the prior map on
expected errors. The source holds the actual next frozen command through eventual
acceptance; it does not withdraw an unaccepted busy offer.

| ORDERS / TAG_W | Management | Events | Completed commands | Held-response clocks | Early next offers | Live resets | Total TB clocks |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 / 1 | 126 | 123 | 249 | 1494 | 244 | 4 | 3857 |
| 8 / 8 | 101 | 168 | 269 | 1614 | 264 | 4 | 6605 |
| 64 / 32 | 105 | 276 | 381 | 2286 | 376 | 4 | 26906 |
| Total | 332 | 567 | 899 | 5394 | 884 | 12 | 37368 |

Each profile also has one initial reset, so raw output reports five resets per
profile. The four in-flight reset probes cancel old lookup, U after confirmed
old erase and before new insertion, held successful Add, and held malformed-event
fault response. Every probe is followed by unconfigured requests and a fresh
CONFIG/Add/QUERY lifecycle. Reset is whole-epoch cancellation, not rollback.

Fixtures exercise A/F/E/C/X/D/U, all four management operations, locate filtering
before fault/malformed checks, global full capacity entirely on either side,
XOR-fold collisions/tombstones, replacement at full capacity, all 64 ID bits,
retired-ID reuse, unsigned quantity/price extremes, C execution-price preservation,
side inheritance, duplicate/collision/missing/underflow failures, sticky fault,
retirable fault responses, configuration changes, CLEAR and CONFIG recovery.
Each ordinary response is held for six clocks, including a real future request
where present. Configured/faulted and counts are part of the packed comparison.

The actual `itch_receiver_state8` example connects unchanged B35 parser output
to this state engine. It checks six wire-format packets and eight state/admin
responses: Add; C at a different execution price; U; parser gap with no event;
explicit INVALIDATE; subsequent retirable state fault; CLEAR/receiver reseed;
and a fresh Add. Parser packet completion remains distinct from state success.

## Evidence mapping and limits

Before importing the oracle, the runner archived ten exact HDL/model/runner/list/
dependency inputs under `executed_inputs`, preserving canonical repository paths.
Post-run verification checked all ten current inputs and archived copies, 22 raw
logs, three vectors, four generated images and both tool executables against the
recorded hashes. `B36_DELIVERY.json` maps every executed input to its byte-identical
delivered path and records the retained evidence hashes. Executable inputs were
not modified after the run; only documentation/manifest/delivery records changed.

This earns LINT_PASS, UNIT_SIM_PASS and INTEGRATION_CANDIDATE for the stated finite
cases, alongside HW_UNVERIFIED. No synthesis, PnR, STA, board test, inherited large
regression, exhaustive domain sweep or full exchange conformance run occurred.
The unexpected-child-response INTERNAL path is source-reviewed, not fault-injected;
it invalidates state without a rollback guarantee after private mutation. RTL cycle
bounds are source-derived, without independent latency assertions. TB run lengths
include stalls and resets and do not establish network rate or hardware throughput.
Price-level aggregation, wider aggregate quantities, feed recovery policy and
snapshot acquisition remain outside this package.
