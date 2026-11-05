# Reviewable future execution contracts

All entries here describe unexecuted future gates. Source authoring does not grant execution authorization. Root owns approval files, outer supervision, execution and Git. Source-only authors must not run any entry, helper, guard, model or HDL tool.

All hashes are lowercase SHA256 of actual bytes. Approval files and independent review receipts are outside this package. Review keys are safe repository-relative POSIX paths and values their exact hashes. At least two distinct independent review receipts are required. `source_files_sha256` exactly equals AUTHOR_SEAL's map. `tools` exactly equals TOOL_INVENTORY's actual path/hash map; Python must also equal the current interpreter. Assertions are mandatory (optimized Python is rejected); bytecode writes are disabled. Approval/path/source/copy/tool hashes are rechecked after work and before/after every HDL child.

## Preparation approval

External JSON fields required by `approval_guard`:

```
schema: anscore-transport-prepare-approval-v1
approved_by: root
author_seal_sha256: <reviewed AUTHOR_SEAL hash>
finite_plan_sha256: <reviewed FINITE_PLAN hash>
tool_inventory_sha256: <reviewed TOOL_INVENTORY hash>
source_files_sha256: <exact AUTHOR_SEAL map>
tools: <exact TOOL_INVENTORY tools map>
independent_reviews: <at least two path:hash entries>
fixed_base_frames: 16
profiles: 4
timeout_seconds_per_tree: 20
automatic_retry: false
preparation_invocations: 1
hdl_execution: false
tool_execution: false
numerical_scope: 16 fixed cut and overlap certificates only
outer_binding_path: <absolute external root-owned binding path>
```

The root-owned outer launcher must create preparation suspended, assign it to a kill-on-close Job Object with no breakaway, write the binding AFTER successful assignment and BEFORE primary-thread resume, and enforce hard20s including spawn/attachment/resume/drain. Binding JSON:

```
schema: anscore-transport-root-job20-binding-v1
approved_by: root
status: ATTACHED_BEFORE_RESUME
operation: prepare
child_pid: <actual suspended preparation PID>
hard_seconds: 20
kill_on_close: true
breakaway: false
approval_sha256: <external approval hash>
author_seal_sha256: <reviewed AUTHOR_SEAL hash>
entry_sha256: <prepare.py hash>
supervisor_sha256: <reviewed sim/process_tree.py hash>
```

The process checks its actual PID, binding path, hashes and all values, and records the binding hash. The outer launcher's raw streams and containment/timeout receipt remain root-owned evidence; the child does not attest that it supervised itself. No outer launcher is executed by this package's authoring. Root supplies the separately reviewed concrete launcher and binding before authorizing preparation. The original reviewed supervisor's attach-before-resume mechanics are in the package for inspection/reuse; outer binding creation is root's responsibility.

Future command shape uses absolute sealed Python and script paths with `--approved-author-seal <hash> --approval <external.json> --outer-binding <external-binding.json>`. Exact package files must match AUTHOR_SEAL before the initial attempt. `preparation/attempt_01/LOCK.json` is exclusive; any existing attempt/prepared/seal/archive blocks rerun. Frozen source copies include AUTHOR_SEAL. Only the copied `sim/model.py` may be loaded, once. It expands the already fixed descriptors, solves only16 named frames, and emits six stored artifacts (four profile text files, certificates, runtime record). Receipt and SOURCE_SEAL bind every original source, copied byte and generated prepared file. A failure keeps originals and makes a copy/hash archive; it never erases the attempt or opens a second one.

## HDL approval

External JSON shares author/plan/tool/source/tools/reviews/frame/profile/timeout/retry fields above with schema `anscore-transport-hdl-approval-v1`, plus:

```
source_seal_sha256: <reviewed prepared SOURCE_SEAL hash>
preparation_receipt_sha256: <reviewed successful preparation receipt hash>
max_children: 25
simulations: 10
named_parameter_rejects: 8
stop_on_first_failure: true
preparation_reexecution: false
children: <exact immutable FINITE_PLAN children array>
```

Future command shape: absolute sealed Python/script paths with `--approved-source-seal <hash> --approval <external.json>`. The controller is metadata orchestration; each of the25 actual compiler/simulator children gets its own Job20 tree and immutable argv/cwd/environment. The controller launches no version probes, fixture/model/checker subprocesses, historical checks, synthesis or additional children. Model is never imported. Source/author/prepared seals and successful preparation receipt/copies must match before the new exclusive `execution/attempt_01/LOCK.json`.

The controller copies exact sources+AUTHOR_SEAL+SOURCE_SEAL+six prepared files, executes only these copies, and guards their complete path/hash set. Five new VVP artifacts must be absent before compilation, nonempty after it, hash-pinned before simulation, and have exactly the sealed absolute VPI module closure. No prebuilt artifact is accepted. Every child raw stdout/stderr byte is retained and hashed; zero diagnostics are required for successful lint/compiles. Simulations use the stored-only strict full-transcript parser and every expected tuple. Rejects require nonzero exit, the specific parameter marker, no timeout/containment error and no emitted VVP. First failure stops; all unstarted children stay NOT_RUN. The failure archive preserves scripts/inputs/raw streams/receipts/partial artifacts. No auto retry, repair, widened timeout, new case or new preparation is present. Successful artifacts stay for independent root review.
