# Semantic preflight and fixed reference

Baseline `ed4eda4fe213da6f6fec793ef911daaabfeba2cc` (published B20).
The full cores tree was searched for Chinese remainder, generalized CRT,
congruence merging, Chinese equivalents and modular inverse. Existing
`modular_inverse` README and complete RTL and `modular_multiply` contract
were actually read. Those produce a single-modulus inverse/GCD or product,
not a canonical solution and least period of two simultaneous congruences.
The new capability is neither an LS dimension variant nor rational projection.
It can prepare simultaneous periodic phase/alignment constraints; it does not
generate clocks or transfer payload.

Before the first RTL edit, complete untrusted upstream texts were read, without
copying, adaptation, import or execution:

- SymPy 1.13.3, repository https://github.com/sympy/sympy
- Annotated tag object `e7c0f3d9002e88ae2518961a22b9aff019615146`, peeled through
  the git/tags API to commit `b4ce69ad5d40e4e545614b6c76ca9b0be0b98f0b`.
- Complete [sympy/ntheory/modular.py](https://github.com/sympy/sympy/blob/b4ce69ad5d40e4e545614b6c76ca9b0be0b98f0b/sympy/ntheory/modular.py),
  8474 bytes, SHA256 `c1835f36be52f03aa2a503412d5311edc3d4360eedc0cdb9c5c2e15c10f5e08e`.
- Complete [LICENSE](https://github.com/sympy/sympy/blob/b4ce69ad5d40e4e545614b6c76ca9b0be0b98f0b/LICENSE),
  7885 bytes, SHA256 `07a5e9819f727b4986ad2829c7a29a6320d42575f720eb24d71b7fef573a0286`.
  The SymPy Development Team BSD-3-Clause terms and complete associated
  Diofant, multipledispatch, PyDy BSD and latex2sympy MIT notices were read.

`solve_congruence` is a semantic reference for noncoprime compatibility and
least-period results. Its gcd/extended-gcd implementation is not used locally.
The original RTL traverses a finite residue orbit with addition/subtraction.
The independent local oracle instead uses GCD and modular inversion, and small
profiles also enumerate all candidate integers. No SymPy dependency is needed.
Reusing the existing inverse/divider/multiplier chain was considered; this
low-rate preparation service chooses a smaller integrated normalization/repeat
datapath at the cost of a larger, explicitly bounded period-dependent latency.

All delivered code is original Apache-2.0 work under root LICENSE/NOTICE.
Production is a single RTL file; no sibling, generated data, ROM, network,
vendor primitive or external memory dependency. Internal B20 test-harness
patterns are reused only for protocol/evidence scaffolding, not computation.
