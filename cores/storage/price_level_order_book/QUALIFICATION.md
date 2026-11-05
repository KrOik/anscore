# Finite qualification

Current status: **LINT_PASS + UNIT_SIM_PASS + INTEGRATION_CANDIDATE + HW_UNVERIFIED**.

The authoritative first execution is
`reports/20261105T174151040875Z/results.json`:11 successful child commands,
three syntax/elaboration checks and four compile/simulation pairs. There were
no failed or retried invocations. All eight executable/file-list/dependency
inputs and their exact pre-tool source copies still match the receipt. Four
vector files were prepared before any HDL child and remain hash-identical.
Descriptive README, qualification and delivery metadata are not program inputs.

| Actual check | Parameters/scope | Observed result |
| --- | --- | --- |
| Icarus `-g2012 -Wall -tnull` | Default top | PASS |
| Icarus `-g2012 -Wall -tnull` | LEVELS=32,TAG_W=32,default32-bit price/quantity | PASS |
| Icarus `-g2012 -Wall -tnull` | Complete default example and dependency closure | PASS |
| Compile and vvp | LEVELS/PRICE_W/QTY_W/TAG_W=1/1/1/1 |117commands,468holds,3reset cases, PASS |
| Compile and vvp |5/9/7/8|135commands,540holds,3reset cases, PASS |
| Compile and vvp |16/32/32/8|179commands,715holds,3reset cases, PASS |
| Compile and vvp |32/32/32/32|243commands,972holds,3reset cases, PASS |

Total:674 checked command responses,2695 held-response cycles and12 explicit
reset cases. Command counts exclude reset-canceled commands. Each observed
response checks status, found, full price/quantity/previous fields, both side
counts, echoed operation/side/tag. Each hold also offers a stable next command
and checks that it is blocked. Reset tests discard logical contents and verify
fresh empty-best results after idle, active lookup/mutation and held-response
ownership. The one-bit quantity profile cannot represent a positive request
larger than a positive stored quantity; underflow is therefore exercised in
the wider profiles rather than claimed for an impossible one-bit case.

Independent model data structures are two plain Python dictionaries; ranking
uses sorted unsigned price keys, opposite direction for bid and ask. It does
not instantiate or simulate the RTL algorithm. Cases include empty sides,
per-side capacity and full replacement, duplicate price aggregation, exact-zero
SUB deletion, missing deletion/subtraction, overflow and underflow without
mutation, all stored rank positions, rejected full32-bit ranks, price0/all-ones,
quantity boundaries, CLEAR_SIDE/CLEAR_ALL, crossed books, deterministic mixed
commands, source gaps and sink stalls. Coverage is finite; no whole-market-feed,
protocol parser, matching engine or exchange integration is certified.

Reused dictionary SHA-256:
`03b9bd7147fb0d0275df0f445aa7ee0895f2ee74d0cb38e57ba20ebce970aa91`.
Reused canonical RAM SHA-256:
`04c0fe8416308c7e9a295d582dc7fee5fd8bbadf2fe4e745632543588c4f7619`.
These original files were not edited. Compilation includes both exact versions
in this wrapper's actual integration. No historical hardware evidence is
inherited by the new composition.

All TB compilations report only missing explicit RTL timescales for the
wrapper and reused sources. Production behavior has no delays; TB timing is
explicit1ns/1ps. Raw stdout/stderr and hashes remain in the receipt directory.
Watchdog/dependency failure branches are source-reviewed, not forced as extra
tests. Generated VVP images remain ignored and task-specific for root-owned
review/cleanup; no cleanup mutation was performed by the worker.

Static review checked complete combinational assignments, one sequential writer
per register, width-safe addition/subtraction, exact bid complement ordering,
count/rank bounds, backend response ownership, range-END draining, zero-value
deletion and shared asynchronous reset. Source lists and the example resolve
from the package root and include every production dependency.

Synthesis, placement/routing, STA, board execution, formal verification,
full regression and PPA/resource/Fmax/market-data line-rate measurement:
**NOT_RUN**. Hardware remains **HW_UNVERIFIED**.
