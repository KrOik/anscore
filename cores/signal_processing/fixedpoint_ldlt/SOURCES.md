# Source and reuse record

New RTL, wrapper, testbench, oracle/runner and documentation are independently
authored ANSCORE code under Apache-2.0, covered by the repository LICENSE.
No third-party source, coefficient table, binary or generated RTL was imported.

Read-only external review before implementation on 2026-11-06 (Asia/Shanghai):

- Official Eigen LDLT API:
  https://eigen.tuxfamily.org/dox/classEigen_1_1LDLT.html . The reference describes
  a pivoted decomposition and semidefinite capabilities. This package explicitly
  supports the different, bounded unpivoted positive-quantized-pivot recurrence;
  it does not reproduce Eigen's numerical robustness claims.
- Upstream implementation header:
  https://github.com/eigenteam/eigen-git-mirror/blob/master/Eigen/src/Cholesky/LDLT.h .
  Its copyright and MPL-2.0 header were inspected read-only before implementation.
- Upstream license:
  https://github.com/eigenteam/eigen-git-mirror/blob/master/COPYING.MPL2 .
  MPL-2.0 was read; no source or license text was copied into this implementation.

Internal semantic searches covered common_scaffold/dsp, dsp_isp_library,
operator_library and production RTL/README files throughout cores, searching
LDLT, Cholesky, Gram-Schmidt and triangular factorization. No equivalent matrix
factor service was found. Existing `linear_solve2x2` returns a solution of one
exact rational system and is not a reusable fixed-point matrix factorizer.

Unchanged internal Apache-2.0 source reuse:

| File | Role | Local modifications |
| --- | --- | --- |
| ../../acceleration/signed_divider/rtl/signed_divider.v | Signed truncation and magnitude wrapper | None |
| ../../acceleration/integer_divider/rtl/integer_divider.v | Iterative unsigned restoring division | None |

Each report captures SHA256 and exact copied input bytes for both dependencies.
The wrapper is synchronous-reset and exposes ordinary valid/ready, matching the
new core's clock/reset domain. No CE conversion, CDC or new divider is introduced.
All consumed denominators are widened positive stored pivots times the fixed
power-of-two scale. Divider error flags are still checked before result storage.

## Exact-byte delivery mapping

The original acceleration files were untracked before this package was added.
Their local manifests identify them as an original parameterized autonomous
restoring recurrence and an original signed transaction wrapper. Repository
`NOTICE` states Apache-2.0 applies to original contributions; neither source has
a third-party attribution or a conflicting file-level license. Their recorded
historical manifest source hashes match the current original bytes. Historical
32-bit synthesis/routing statements in those untracked package READMEs are not
new qualification for this wider factorizer and are not inherited.

| Tested original | Final delivery path (from package root) | SHA256 |
| --- | --- | --- |
| ../../acceleration/integer_divider/rtl/integer_divider.v | ../../image_processing/grayscale_anisotropic_diffusion/rtl/deps/integer_divider.v | e09b6e9501a02fbcb0a89be50b5a0b787c71e9180b934b32d446601a299c5f6c |
| ../../acceleration/signed_divider/rtl/signed_divider.v | rtl/deps/signed_divider.v | 4266d7445838ed07f962365e153e184d48abb21dded2145b868bf2488d14d93c |

B31 `source_20261106_b31_structure.json` already lists that canonical integer
source and its module declaration. It contains no `signed_divider` declaration.
Referencing the existing integer file and adding the signed wrapper once avoids
a duplicated global module name. Source lists compile one copy of each module.
The wrapper retains its original bytes; provenance is supplied here rather than
inserting a header into historically checked source. Original-to-final mapping,
current list syntax evidence and inherited unit source hashes are recorded in
`QUALIFICATION.json`. No existing source was edited or staged by this package.
