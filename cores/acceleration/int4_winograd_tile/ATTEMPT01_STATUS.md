# First attempt retained: preparation syntax failure

The original frozen B50_WINOGRAD_ONCE_01 attempt ran once. Its only inner
child was prepare_vectors, exit1: Python rejected an unclosed parenthesis
in the record formatter at archived model/reference.py line71. No fixture
file, HDL compile, simulation or VVP image was produced. This was a model
source syntax failure missed by root and independent peer review, not a
numeric or RTL test result. All HDL checks remain NOT_RUN; HW_UNVERIFIED.

The controlled sequence stopped immediately. The child exited in0.094s
(0.110s including capture); the outer finite_runner exited1 in1.766s.
No timeout, termination helper or unconfirmed process remains. Terminal/raw
records report the actual nonzero exits; no PASS or automatic retry occurred.

Original evidence and archived source/plan/seal/review remain untouched at:

* reports/20261106T201511289779Z/results.json
* reports/20261106T201511289779Z/prepare_vectors.initial.json
* reports/20261106T201511289779Z/prepare_vectors.json
* reports/20261106T201511289779Z/prepare_vectors.stdout.raw
* reports/20261106T201511289779Z/prepare_vectors.stderr.raw
* reports/20261106T201511289779Z/executed_inputs/
* repository-local .git/anscore-b50-winograd-launch/results.json and captures

Both original once guards remain, prohibiting reuse of the original runners.
The earlier source-draft NOT_RUN statements describe the pre-attempt freeze;
this status note supersedes them for preparation execution only.

An additive unexecuted followup01/model/reference.py changes only the
record formatter into two statements (construct12 values, join as text).
No transform, spatial oracle, quantization, fixture, input count, test or
deadline is changed. It is a repair candidate, not an executed preparation
or a qualification result. A separate full-source review and explicit exact
finite follow-up gate are required before any further child can run.
