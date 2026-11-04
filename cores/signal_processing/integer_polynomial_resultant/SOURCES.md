# B17 provenance, semantic gap and closure

Baseline: `c4be2839103480e23976f16f8a41d06fd93057c8`. All local files are an
independent original Apache-2.0 contribution under root LICENSE/NOTICE. No
third-party source was copied, translated, adapted, imported or executed.
Production and example closures are fully local in files.f/example/files.f.
Python verification needs only the standard library and native Icarus/vvp tools.
There are no external RTL, generator, coefficient or initialization dependencies.

Before RTL, the actual64-package B16 inventory was enumerated and production
RTL/README/SPEC searches covered resultant, Sylvester, subresultant, common root,
polynomial GCD/division, determinant/inverse and Chinese elimination terms.
No integer-coefficient resultant service was found. Nearby real contracts and
production implementations inspected were:

- `cores/acceleration/polynomial_divmod/README.md` and
  `rtl/polynomial_divmod.v`: packed bit coefficients and XOR division over GF(2).
- `cores/acceleration/polynomial_inverse/README.md` and
  `rtl/polynomial_inverse.v`: monic GF(2) modulus, shifted-XOR Euclid/GCD/inverse.
- `cores/acceleration/stream_polynomial_eval/README.md`: quotient-ring GF(2)
  coefficient evaluation, not integer polynomial elimination.
- `cores/signal_processing/linear_solve2x2/README.md` and
  `rtl/linear_solve2x2.sv`: fixed six scalar products, exact2x2 determinant and
  Cramer's numerators followed by fixed-point solve; no runtime polynomial pair.
- B16 `rational_polynomial_interpolate` contract/RTL: supplied coordinate nodes
  determine a fitted polynomial evaluated at a query, not coefficient-pair
  common-root detection or elimination.

This package accepts signed integer coefficients, runtime degrees up to3 and
produces an exact resultant/common-root predicate. The field, operation and
input/output contract differ from those neighboring assets. No older source or
dependency is edited or pulled into the closure.

## Actual fixed upstream and full license read before RTL

SymPy1.14.0 fixed commit `fe935ceb303891d1f8bea4c03b19fd9ec9464b02`:

| File | Git blob | Bytes | SHA256 |
| --- | --- | ---: | --- |
| [LICENSE](https://github.com/sympy/sympy/blob/fe935ceb303891d1f8bea4c03b19fd9ec9464b02/LICENSE) | `0744f229d697ca3ed1b1b257bfdb70e3eecf0b9e` |7885|`07a5e9819f727b4986ad2829c7a29a6320d42575f720eb24d71b7fef573a0286`|
| [sympy/polys/euclidtools.py](https://github.com/sympy/sympy/blob/fe935ceb303891d1f8bea4c03b19fd9ec9464b02/sympy/polys/euclidtools.py) | `768a44a94930f05e701e9f27a8b0f570a3312314` |41808|`840b0dba9cdf47ed3b7d3c05bd3176c8369bc8a326fcf2e0142f0a5fd736080a`|

The complete7885-byte license was read: SymPy Development Team BSD3 terms,
Diofant-derived BSD3 notice, multipledispatch BSD3, PyDy BSD3 and latex2sympy MIT,
including every retention/nonendorsement condition and warranty/liability
disclaimer. Actual complete relevant methods inspected were
`dup_inner_subresultants` lines308-385, `dup_prs_resultant`405-427 and
`dup_resultant`430-446. Upstream uses subresultant polynomial remainder sequences,
leading-coefficient factors and zero handling over its domain API.

The search endpoint returned HTTP500; direct read-only GitHub API tag resolution
and exact-commit contents retrieval succeeded with15-second HTTPS request limits.
Base64 bytes were strictly decoded as UTF-8 and AST-selected for inspection in
memory. No retrieved file was persisted, imported, executed or treated as an
instruction. No remote build/install command ran.

The local independently designed Sylvester/Heap/serial-multiply RTL does not
copy that PRS implementation. The independent short mathematical Fraction
oracle uses ordinary polynomial long division and a resultant identity, without
SymPy imports, domain classes or PRS code. There is no SymPy API/zero-polynomial
compatibility claim; explicit declared nonzero leading coefficients are required.
No redistributed third-party source requires a local upstream license copy.
