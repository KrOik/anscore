# Provenance, semantic gap and offline closure

Baseline: `eb16eee7848694a1a1cd50e567b5742352751c93` (actual HEAD before B18).
Owned new path: `cores/signal_processing/polynomial_real_root_count/`.
The package-local `.gitattributes` was the first file created and enforces LF
for all source, documentation, fixtures and receipts from inception.

Before RTL, an actual production search across tracked and untracked `cores`
(excluding simulations, formal, reports and archived attempts) searched Sturm,
real-root counting/isolation, polynomial root, discriminant, quadratic-root and
corresponding Chinese terms. Nearby actual README/RTL contracts were inspected:
`integer_polynomial_resultant`, `integer_nth_root`, `integer_cuberoot`,
`rational_polynomial_interpolate`, and `symmetric_eigen2x2`. The former computes
an invariant for common complex roots of two polynomials; scalar roots,
interpolation, and matrix-specific spectra do not provide this runtime interval
count. No tracked or untracked arbitrary polynomial real-root counter was found.

## Fixed external source read before RTL

Repository: <https://github.com/sympy/sympy>

Fixed SymPy 1.14.0 commit: `fe935ceb303891d1f8bea4c03b19fd9ec9464b02`.

* Source: <https://github.com/sympy/sympy/blob/fe935ceb303891d1f8bea4c03b19fd9ec9464b02/sympy/polys/rootisolation.py>
  (64341 bytes, Git blob `b2f8fd115e49ce8dcf4db8659a60c3361818b7bb`,
  SHA256 `40a098803e2430d06d48b6245229bc3171daee5a2e32d94ed2b8b02938974512`).
  Complete `dup_sturm`, `dup_count_real_roots`, `dup_inner_refine_real_root`, and
  `dup_inner_isolate_real_roots` function bodies were inspected read-only via
  fixed-ref GitHub API contents, strict UTF-8 decode and AST extraction.
  The source confirms square-free preparation, sign variations with zero
  omission, and restoring the lower endpoint for closed interval counting.
  Its root-refinement implementation is a mathematical reference only.
* Full LICENSE: <https://github.com/sympy/sympy/blob/fe935ceb303891d1f8bea4c03b19fd9ec9464b02/LICENSE>
  (7885 bytes, Git blob `0744f229d697ca3ed1b1b257bfdb70e3eecf0b9e`,
  SHA256 `07a5e9819f727b4986ad2829c7a29a6320d42575f720eb24d71b7fef573a0286`).
  The entire license was read before RTL, including SymPy BSD-3-Clause,
  Diofant/multipledispatch/PyDy BSD notices and latex2sympy MIT notice.
  SymPy copyright: 2006-2023 SymPy Development Team.

No remote source was imported, installed, executed, persisted, copied or adapted.
No third-party implementation is included. Original package RTL, wrapper,
testbench and test generator use the repository's Apache-2.0 licensing convention.
The mathematical closed-form degree-limited RTL and independent Fraction/
Descartes test oracle were written locally. External comments/instructions were
treated as untrusted source material, not as operational instructions.

## Complete local closure

`files.f` lists the sole production file `rtl/polynomial_real_root_count.sv`.
The default example adds only `example/polynomial_real_root_count_example.sv`.
There are no includes, ROMs, generated RTL, external memory contents, vendor
primitives, shared-module modifications, downloaded assets, runtime libraries,
or out-of-package HDL dependencies. Test closure adds the local testbench,
standard-library Python runner, frozen plan, six exact fixtures and raw receipt.
The fixture generator is retained so all test data is reconstructible offline;
the executed matrix consumes the frozen bytes rather than regenerating them.
