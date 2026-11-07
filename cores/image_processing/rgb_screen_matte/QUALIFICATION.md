# Finite qualification record

Status: **FINITE_SIMULATION_PASS / HW_UNVERIFIED**.

The single approved attempt `20261106T203545506685Z` (UTC) completed under gate
`B50_MATTE_ONCE_01`, against baseline
`c9117a22459e954d496dfa66dd94d6f67188c862`. Root executed the reviewed outer
supervisor once; worker_a independently audited the retained evidence using
native file/JSON/hash reads. The audit did not rerun preparation, HDL or Git.
The pre-execution README, manifest and frozen controls remain unchanged; this
additive note records the later observed result.

## Observed finite checks

Seven planned targets completed with actual exit code 0 and terminal PASS:
one independent preparation, minimum-tag core and example elaboration, and
compile/simulate pairs for core TAG_W=32 and example TAG_W=28. All seven
initial, seven terminal and seven validated sidecars and all fourteen raw
streams matched their recorded hashes and sizes. Actual argv/cwd and target
order matched the frozen plan. No target timed out or used termination cleanup.

Preparation retained 1,262 rows of eighteen fields. Native inspection found
all 256 alpha bytes, 210 invalid windows and six exact-half cases, matching the
preparation metadata. The fixture and preparation record were validated and
frozen before the first HDL child.

| Actual simulation | Rows | Held-output checks | Live-reset probes | Unmatched reset probes |
|---|---:|---:|---:|---:|
| Core TAG_W=32 | 1262 | 1107 | 5 | n/a |
| Actual source-over example TAG_W=28 | 1262 | 1383 | 5 | 2 |

Both simulations reached their PASS marker and `$finish` with empty stderr.
The reviewed tests enforce ordered data/status/metadata, held-output stability,
15/18-cycle dense latency and II=1, cancellation of live pipeline tokens, and
post-drain quiet windows. The example also checks atomic foreground/background
acceptance and unmatched-input reset cancellation. Its retained image contains
both the matte and real `rgba_porter_duff` module scopes; the dependency source
is unchanged.

The example elaboration and compile each retained twelve Icarus constant-select
sensitivity notices from the canonical Porter-Duff source, 2,172 stderr bytes
per command. Those commands returned 0. Their raw notices remain intact.

## Evidence integrity

The audit matched all 21 current source pins, all 21 archived source copies,
and all 30 tool pins. Current and archived plan/seal/review bytes matched.
Both retained images matched their compile records, execution records and
exclusive STARTING/null-PID image-hash sidecars written before Popen.

The outer supervisor returned 0/PASS in 8.109 seconds, within its 20-second
limit, with complete raw capture and no cleanup. Its single child and all
seven inner targets exited; active-child/helper fields are empty. Native
process observation found none of the eight recorded PIDs still present.
Both exclusive once guards remain retained with their original pins. No
retry was performed.

Evidence directory: `work/20261106T203545506685Z/`.

| Artifact | SHA256 |
|---|---|
| Inner `results.json` | `016aba9267f2589723d6e89b3ed0fa2344c4ed57689fb26329cc8d77b7440fc7` |
| Root `.git/anscore-b50-matte-launch/results.json` | `d6279cbec443d4830b8d1345da640ef8ee8f8c28c5037d4f1ba231d8b6727247` |
| Vectors | `9916d8e8c83281b8ac159858abf1eff220cfbd0f2ce7b6e6eb960f4ba8491779` |
| Core image | `89bb1dd05bf551f5c5ab78a2f3dbe32e566a1ad504678201281da45dfe111c8e` |
| Example image | `22280c553d702ba5ea9e4b7f49ddd404dc8aeb7966545041ba83d60ac8433dbc` |

## Qualification boundary

This establishes the reviewed finite simulation matrix and this actual
composition only. Minimum-tag configurations were elaborated; they were not
separately simulated. It does not establish exhaustive coverage, formal proof,
synthesis, mapped resources, PnR, STA, Fmax, power, board behavior, physical PPA,
or historical regression. Hardware remains **HW_UNVERIFIED**.
