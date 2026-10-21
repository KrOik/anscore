# Read-only hold report qualification (host tests)

Current real GW5A model/tool qualification: **UNPROVEN**. No real qualification
certificate is created by this change. The validator cannot pack, program the
board, apply RTL, or write evidence. A host-fixture PASS authorizes none of these.
The existing release scripts and old route/setup summaries are unchanged.

## Executable host test

From `D:\sipeedTANG20K`, using Python 3.11 or newer:

```powershell
python -B cores/system/common_scaffold/board/tang25k/sim/hold_qualification_20261017/run_host_tests.py --summary cores/system/common_scaffold/board/tang25k/sim/hold_qualification_20261017/host_test_summary.json
```

The receipt records the actual command, Python version, source SHA256s, each
expected/observed result, read-only checks, and cleanup checks. Candidate-like
files are generated with `TemporaryDirectory` in system temp and deleted after
each case. One negative test uses a disposable root inside this test directory
to prove that fixture mode rejects roots outside system temp; that root is also
deleted. No fabricated report or reviewed-production PASS certificate is kept.
Use `-B` to avoid `__pycache__`. Only the small JSON host-test receipt persists.

The positive API case has `fixture_only=True`, a qualification carrying
`fixture_only: true`, an explicit fixture qualification SHA, and a system-temp
root named `.hold_qualification_fixture_*`. Its result always carries
`scope: HOST_FIXTURE_ONLY` and `production_qualification: NOT_AUTHORIZED`.
There is deliberately no CLI fixture switch. CLI tests prove missing reports,
absence of trusted qualification, and misuse of a trusted fixture all block.

## Actual producer schema and numerical checks

The consumed producer is
`scratch/nextpnr_hold_min_20261017/source/common/kernel/report.cc`, with aggregation
in `timing.cc` (`TimingAnalyser::walk_paths` result aggregation). Its report has a
root `hold_timing` object with all of the following fields:

| Field | Required type / meaning |
| --- | --- |
| `status` | `NOT_RUN`, `UNPROVEN`, `FAIL`, or `PASS` |
| `endpoints` | Nonnegative integer register-input endpoint count |
| `candidate_paths` | Nonnegative integer relevant launch/capture path count |
| `timed_paths` | Nonnegative integer paths with complete delay information |
| `unknown_paths` | Nonnegative integer unknown paths, including endpoints without a candidate |
| `violations` | Nonnegative integer paths with slack **less than or equal to zero** |
| `worst_hold_slack_ns` | Finite number when a path is timed; explicit `null` otherwise |
| `reason` | Producer reason corresponding to the status and counts |

The producer's default `NOT_RUN / analysis_not_run` requires every count zero
and slack null; it yields an UNPROVEN blocker. No candidates yields
`UNPROVEN / no_constrained_hold_paths`. Missing/unknown timed paths yields
`UNPROVEN / incomplete_delay_model`. A known violation takes precedence over
unknown paths and requires `FAIL / known_hold_violation`. PASS requires
`all_candidate_paths_timed`, nonempty complete endpoint coverage, no unknowns,
all candidates timed, zero violations, and strictly positive finite slack.
Zero slack with zero violations is a numerical contradiction and fails.

Counts reject Boolean, fractional and negative values. The checker enforces
`timed <= candidates`, `violations <= timed`, and
`candidates - timed <= unknown <= candidates - timed + endpoints`.
Endpoint unknowns can therefore legitimately make unknown exceed candidates.
The JSON loader also rejects duplicate keys, NaN and infinity; overflowing JSON
numbers cannot qualify. A missing field or report never becomes implicit zero.

## Explicit binding manifest

`qualify_min_delay_report.py` consumes a separate manifest with
`schema: gw5a-min-delay-bindings-v1`, an integer `op` in 0..2, `artifacts`, and
`analysis`. It does not rewrite the producer report or old summary fields.
Each required artifact has `{ "path": "root-relative/path", "sha256": "64 hex digits" }`.
Required roles are:

```text
report source_freeze op_freeze input_netlist routed_json
original_cst derived_cst chipdb timing_binary producer_source_manifest
run_log model_qualification qualification_review qualification_tests
```

All paths must resolve within `--artifact-root`; absolute/drive paths, `..`,
missing or empty files, and changed hashes block. The report argument must select
the exact bound report. Both freeze documents require `verification.result:
PASS`; OP freeze requires matching `op` and `parameters.OP`, and
`verification.source_freeze_sha256` must bind the actual source freeze.

`analysis` requires the following explicit values:

```json
{
  "complete": true,
  "mode": "post_route",
  "with_clock_skew": true,
  "setup_only": false,
  "fast_pip_delays": false,
  "process_returncode": 0,
  "clock_domains": ["actual-constrained-clock"],
  "command": ["actual-timing-tool", "actual-arguments"]
}
```

Clock domains must be nonempty, unique and constrained (`<async>` is rejected).
The command is recorded argv, not executable input to this validator. Manifest
declarations alone cannot qualify a tool or model: independent review and a
separate explicit qualification pin are required below.

## Model/tool trust boundary

No qualification hash is trusted by default. The integrating owner must review
the model/tool and underlying evidence independently, then supply that exact
SHA via `--trusted-qualification-sha256`. Reading a nonempty file or finding
`status: PASS` does not establish trust. A hash must not be auto-derived from an
unreviewed file and fed back as its own trust decision.

The qualification schema is `gw5a-min-delay-model-qualification-v1`. It requires
the matching `fixture_only` scope, reviewed `status: PASS`, a nonempty `reviewer`,
and all these `capabilities` set to literal Boolean true:

```text
fast_min_routing slow_max_routing dual_corner_rc wire_unknown_propagation
clock_skew_minmax sequential_hold_arcs unknown_paths_fail_closed
```

`artifact_sha256` in that qualification must bind these exact actual artifacts:
`timing_binary`, `chipdb`, `producer_source_manifest`, `qualification_review`,
and `qualification_tests`. The outer explicitly pinned binding manifest also
binds the qualification file. This breaks no trust circularity: trust originates
in the external reviewer and explicit CLI/API hash, not inside the sidecars.

There is currently **no real trusted qualification SHA**. The host test creates
only `fixture_only: true` qualification documents, inside disposable roots.

## Integration interface and exit codes

Illustrative future invocation, after real independent qualification exists:

```powershell
python -B cores/system/common_scaffold/board/tang25k/qualify_min_delay_report.py --report <report.json> --binding-manifest <bindings.json> --expected-binding-sha256 <reviewed-binding-sha256> --trusted-qualification-sha256 <independently-reviewed-qualification-sha256> --artifact-root <artifact-root>
```

The placeholders above are explanatory and were not executed. The CLI prints
JSON to stdout and exits 0 for PASS, 1 for FAIL, or 2 for UNPROVEN. Missing
evidence or untrusted/incomplete qualification remains UNPROVEN; contradictory,
corrupted or violated evidence fails. A qualified real report would still say
`HOLD_ARTIFACTS_PASS_OTHER_RELEASE_GATES_REQUIRED`: setup timing, resources,
packing, repeated SRAM/UART board checks and production integration remain
separate gates. This host change runs no synthesis, PNR, pack, hardware access,
production update or broad RTL regression.

Future release scripts should all call this single validator, explicitly pin
the exact attempt and all evidence, and retain its receipt without modifying
old route-only reports. Integration sequencing and any real trust decision are
owned by the parent task; this change edits none of those scripts.
