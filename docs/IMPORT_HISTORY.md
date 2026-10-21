# Source import history

The original LICENSE commit is retained unchanged. At the maintainer's
request,the former519 partial source-import commits are consolidated into
one complete source checkpoint. main therefore contains exactly two commits:
the original LICENSE commit and the consolidated source/documentation commit.
The consolidation uses the current commit date;historical per-batch dates are
not evidence of development or validation activity. The old main tip and a
Git bundle are retained locally before the protected history update.

The source checkpoint also refreshes allowlisted functional packages from the
workspace,including the25K work-order implementations and their documented
open acceptance gates. docs/ip_asset_25k/STATUS.md is an engineering ledger;
it does not assert that every package has completed board or release review.
The new motor replay owner is explicitly WIP,not qualified or integrated.

Git excludes toolchains,netlists,bitstreams,waveforms,capture caches,logs,
machine connection information and secrets. These local artifacts are not
removed. Necessary source tables/vectors and interface/validation documents
remain versioned. Workspace-specific artifact paths in historical reports
refer to local evidence,not files guaranteed in this source-only checkout.
Some fixture-driven host checks require that separately retained evidence.
Physical25K/runtime hard-user-JTAG/LA and licensing gates remain as recorded.

scripts/sync_workspace_sources.py performs allowlisted source refresh only.
It never fabricates dates,imports commit batches,or rewrites Git history.
