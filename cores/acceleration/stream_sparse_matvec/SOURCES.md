# Search and originality record — 2026-11-04

Baseline: `6d1af43`. Production RTL, README/SPEC and filename searches for
SpMV, sparse matrix and CSR arithmetic found no equivalent reusable module.
`sparse_dot`, `duplicate_sparse_dot` and `unsorted_sparse_dot` intersect two
sparse vectors; they do not cache one dense vector and gather its indexed
elements across multiple independently delimited matrix rows. CNN/systolic
operators have different coefficient, schedule and framing contracts.
No existing RTL or its historical validation evidence was modified.

Before implementation, GitHub REST repository searches were performed read
only for `spmv verilog` (no returned repositories) and `sparse matrix FPGA`.
Returned candidates included:

- https://github.com/linghaosong/Sextans, branch `tapa`, repository metadata
  reports MIT. Attempts to retrieve a fixed commit, source tree and actual
  LICENSE/README failed repeatedly with transient TLS EOF. No source text,
  license text or fixed SHA was obtained, so it was not adopted. The metadata
  classifier alone is not treated as a verified permission grant.
- https://github.com/SFU-HiAccel/HiSpMM, branch `main`, metadata reports
  BSD-3-Clause. This was only a search candidate; no source was incorporated
  and no claim of a completed file-level license audit is made.
- `balos1/fpga-sparse-matrix-mult` and `Duchstf/SparseButterfly` had no declared
  license in returned repository metadata and were excluded from incorporation.

The bounded cached-vector/row-stream implementation was independently designed
from the integer matrix-vector definition. No third-party code was copied,
translated, adapted, generated or redistributed. Therefore there is no adopted
upstream file, fixed upstream version, local third-party modification or
transitive RTL dependency. All delivered RTL, example, tests and prose are
original Apache-2.0 code under the repository license. No upstream script,
installer or build workflow was executed. Internet availability is unnecessary
for offline compilation or finite unit checks.
