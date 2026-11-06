# B39 finite qualification

LINT_PASS + UNIT_SIM_PASS + INTEGRATION_CANDIDATE + HW_UNVERIFIED.
The current core/example RTL and TB are byte-identical to the initial frozen
execution inputs. There are **12 PASS children, one retained FAIL, four
successful simulations**, and no tool timeout. No passed profile was rerun.

Initial receipt: reports/20261106T054308266995Z/results.json,
SHA256 c5ab104ae7397303865eccb237bbb263089fbd17a6626117e5cc6b672652d73f.
It records ten PASS and one FAIL. Default/max/example syntax and core capacity
1/T1,37/T8,4096/T32 simulations passed. The actual example failed at command4:
input length0 encoded total_length20, and hardware correctly returned the
originally documented BAD_HEADER8 while its reference fixture expected RANGE2.
The run stopped. Original plan, source/vector bytes, raw logs and failed VVP
remain bound by FAILURE_ARCHIVE.json; the failure is never reclassified PASS.

The only functional verification-source change was vector_plan's explicit
header validity requiring positive payload length. This changes exactly one
expected status in the example vector and the corresponding statistics. No
RTL, TB, input transaction, header checksum, time bound or numerical tolerance
was changed. No core vector/profile was rerun. Initial planning used four
pre-execution revisions with16 numerical planning calls; initial frozen
execution generated four vectors. The explicit repair generated one vector
after its11 source inputs were archived, with zero repair planning model calls.

EXAMPLE_REPAIR_PLAN.json was independently source-reviewed by workerA, adding
strict actual TB coverage-counter enforcement before execution. Only the
failed example was compiled/simulated in reports/20261106T054818225882Z/results.json,
SHA256 4fa135c959c34c85e868a3211f080b0ebdedc0fb33d95733035fabdc18d3a778.
Both children PASS; plan SHA256
28fed66268cf9d5242fd3550fc1c6842904b5388798f494e4ccef7d83820da41.
Both executions had20s/child, bounded7s cleanup, fail-stop and no automatic
retry. A further repair is not authorized by either runner.

The four successful simulations checked361 commands,855 input bytes,735
ordered replay bytes,27 resets including initial resets,3256 held clocks and
four genuinely offered future FLUSH commands. The example checked120 commands,
285 input bytes,245 replay bytes,8 resets and1084 held clocks, including legal
all-ffff and all-zero source/destination/id/protocol headers and six rejected
headers (one zero-length and five explicit malformed cases). Max capacity4096
used short packet/replay cases and a storage-tail fragment, not a full4096
publication. These finite observations do not prove arbitrary packet traffic.

No synthesis, PnR, STA, board operation, PPA, full-network integration or legacy
regression was run. No line-rate, Fmax, memory inference or physical fit claim.
