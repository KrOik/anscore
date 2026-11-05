# Fixed qualification gates

SOURCE_ONLY, RTL_CANDIDATE, HW_UNVERIFIED. No numerical materialization, model,
stored checker, compiler, simulator or package entrypoint has run. Source
authoring uses only file reads/writes, stdlib AST/JSON parsing and hashes.

AUTHOR_SEAL.json lists every source file, with no generated fixtures. The
preparation approval is an external root-owned .git JSON with stage=prepare,
approved_by=root, approved_author_sha256, max_invocations=1,
hard_seconds_per_tree=20, automatic_retry=false and at least two independently
reviewed path:SHA256 receipts. The reviewed command is:

```
python -B run_tests.py prepare --approved AUTHOR_SEAL_SHA256 --approval EXTERNAL_JSON
```

The controller guards the exact author inventory and baseline, copies sources
into the exclusive preparation/attempt01/tested_source directory, and launches
that frozen prepare.py in a kill-on-close Windows Job. The child is suspended
until assigned, then resumed with a deadline measured from before launch.
prepare.py itself rechecks the approved seal, external approval, sources and
destination before importing reference.py. Existing attempt or output blocks
another invocation. Only the23 named CASE_TABLE frames are materialized/solved,
once each; the14 feasible reference witnesses are checked directly. No other
graph, Cartesian input sweep or inherited numerical check is prepared.

Preparation writes DATA.json and12 fixed text fixtures plus MANIFEST.json,
14 files total. Normal jobs contain23 main frames. Six reset jobs reuse stored
owner/fresh cases, not new solves, making35 fixture frames,29 completed frames
and6 cancelled owners. A single held next-frame beat in main_p3 is accepted
then reset; it is explicitly incomplete and not an extra numerical case.

The root reviews actual preparation raw stdout/stderr, containment receipt,
tested source inventory and generated hashes before constructing SOURCE_SEAL.
That seal records author_sha256, preparation_receipt_sha256,
test_plan_sha256, the exact TEST_PLAN children array and input_files_sha256.
The latter includes all author sources plus AUTHOR_SEAL, all14 prepared files,
the actual preparation receipt, its approval copy and both raw streams. Tested
preparation copies are separately required to retain their exact approved map.
The preparation receipt's approved author, original approval path/hash,
manifest hash, child receipt/raw hashes and source copies are checked before
HDL setup and before/after every child. A substituted internally consistent
prepared directory cannot replace the original PASS receipt/manifest binding.

A separate external stage=hdl approval with approved_seal_sha256 and the same
one-invocation/Job20/no-retry/review fields enables exactly29 children:
stored-certificate check,2 lints,5 compiles,6 main simulations,6 reset simulations
and9 named parameter rejects. No model is imported in this phase. Production
files.f paths are relative to the copied package root. The runner requires
fresh VVP artifacts and exact6-module VPI closure. It pins sources, tools,
complete search-directory inventories, approval and artifacts at each boundary.

Every raw byte is saved before interpretation. The TB records actual PIN/POUT
samples, frame boundaries, held offers, real NEXTIN, CUT predicates, all asserted
reset edges and termination. The stored parser checks their order and all
fields. Its direct witness checks use only supplied edges, membership,
positive weights, ascending unique pairs, acyclicity, connectivity, count,
bitmap and cost against the stored optimum. Tied optimal witnesses may differ
from the independent reference witness. Invalid or disconnected frames require
the contract's zero-field summary and diagnostic flags.

Each compiler/simulator/checker/preparation child has a hard20s process-tree
deadline; cleanup drains already killed processes for at most0.5s. First
failure stops. The exact inputs, copied sources, raw streams, child receipt and
partial artifacts remain in place with FAILURE_ARCHIVE.json. No retry path,
automatic repair, timeout regrouping or inherited check is provided. Successful
VVPs remain temporary review artifacts until root separately audits/removes
them; they are not production dependencies. All physical results remain unmeasured.
