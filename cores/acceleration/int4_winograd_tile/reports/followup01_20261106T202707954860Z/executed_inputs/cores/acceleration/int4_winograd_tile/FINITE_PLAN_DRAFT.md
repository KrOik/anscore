# Unexecuted finite qualification draft

All project, model, helper, AST, compiler, simulator and Git checks for B50
are NOT_RUN. This document is not execution approval. Root plus an
independent peer must read the full final source closure and bind exact
bytes/tool metadata/argv/cwd/environment/deadlines before any child launches.

Proposed single preparation child: `model/reference.py --out <new run vectors>`.
It creates only an exclusive task output directory and four deterministic
ASCII fixtures plus one JSON manifest. Its golden values are direct spatial
3x3 integer sums. A separate exact matrix calculation checks the transform
identity and divisibility by four for every configured row/tile used.

Proposed HDL scope: standalone core MAX_ROWS/TAG_W = 1/1, 3/17, 64/32 and
actual requantization wrapper at8/32. Each has one syntax/elaboration child,
one compile child, one simulation child (12 HDL children). No parameter
sweep, seed search, physical flow or historical regression is authorized.
The precise final plan may remove redundant elaborations but must not add
unreviewed children. Use the unchanged canonical stream_requantize only for
the wrapper and the exact finalized package testbench for all four cases.

TB/oracle cases cover all-negative/all-positive and alternating kernels;
U8/zero extrema, random deterministic tiles, maximum row count/tag; S32 bias
extrema; malformed early/missing LAST with exact full16 input consumption;
missing/incomplete/stale publication, rejected row/tap/shift atomicity,
publication/reuse/invalidate; zero scale, shift0/31, exact positive/negative
half ties and RNE before odd output-zero translation; final S8 clipping.
Ordinary RV backpressure checks every visible result/config/summary field.
Input/config/command payload changes after acceptance test captured ownership.
Simultaneous config/command checks config priority and held-command retry.
Resets target held config response, transform publication, partial capture,
input transform, product, held output and final response, plus a held public
requantized output in the real wrapper. Following each reset, a missing-row
command must fail before fresh configuration and recovery are exercised.
The HDL watchdog is bounded at200000 rising edges. No counts or PASS claims
exist until retained raw execution evidence supports them.

Every child:20 seconds; a necessary tree-kill helper:5 seconds; after kill,
the sole target-exit observation:2 seconds. Failure/timeout halts later
children, without automatic retry. The exact compiled image SHA/prechecked
record must be exclusive-created and fsynced in an immutable initial sidecar
before simulation Popen; retain separate terminal and validated records,
raw stdout/stderr, frozen executed inputs and the original ignored image.
Do not replace, delete or relabel failed evidence. No synthesis/PnR/STA,
board testing, PPA or inherited hardware qualification is in scope.
