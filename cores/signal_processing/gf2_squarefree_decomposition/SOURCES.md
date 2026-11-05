# Scope, semantic comparison and provenance

Baseline: `548ecff2b34281ec7b6f3306ba1c8d3af07f246d` (B26 publication).
Root owns Git, shared documentation, original guards and snapshot integration.
This package does not modify, execute or inherit qualification of another IP.

The 104 cumulative package objects and production DSP/acceleration paths were
searched for squarefree decomposition, multiplicity groups, Smith/Hermite
forms, polynomial arithmetic, exact linear solve and rational outputs.
Actual current interfaces were read before choosing this capability:

- `gf2_polynomial_irreducibility` returns one Rabin classification and witness;
  it explicitly does not factor or group repeated components.
- `polynomial_divmod` returns one quotient and remainder. Its production RTL
  and README were read completely. It is protected original untracked work,
  so it is not a legal dependency of this committed package.
- Integer resultant, real-root count, rational interpolation and integer
  characteristic-polynomial production interfaces use different domains and
  do not return GF(2) squarefree multiplicity groups. The 2x2 linear solver
  returns quantized unique solutions and a singular flag, another capability.

The new RTL owns only the minimal shared GCD/quotient remainder path required
by the decomposition service. It does not copy, stage, execute or depend on
the protected polynomial divider, nor modify the irreducibility package.
There is no additional standalone duplicate arithmetic package.

## Fixed external read-only review

Repository: https://github.com/sympy/sympy

Commit: `fe935ceb303891d1f8bea4c03b19fd9ec9464b02` (SymPy 1.14.0 reference).

The official API returned these exact objects before implementation:

| File | Git blob | Bytes | SHA256 |
|---|---|---:|---|
| `sympy/polys/galoistools.py` | `b09f85057eced59b8054c6007f2b291a35a2fafb` | 57238 | `67779dfc0d0da218fd473b8cde4a26efe6b2e0c9f3207a69c2057642938db93a` |
| `LICENSE` | `0744f229d697ca3ed1b1b257bfdb70e3eecf0b9e` | 7885 | `07a5e9819f727b4986ad2829c7a29a6320d42575f720eb24d71b7fef573a0286` |

Complete `gf_diff` lines 1198–1225, `gf_sqf_part` lines 1574–1595 and
`gf_sqf_list` lines 1598–1684 were inspected. They establish the characteristic-p
derivative/GCD/quotient and Frobenius-root decomposition. The local interface's
explicit stream order is defined by README, rather than inferred from an
external docstring. The entire upstream license was read; its relevant SymPy
notice is BSD three-clause. The complete license, including other bundled
notices, is retained byte-exact as `LICENSE.SYMPY`.

The web search service returned HTTP 500. Explicit read-only HTTPS requests to
the official GitHub API at the fixed commit supplied the source and license;
no remote installer, build, project script or math library was executed.
Only the license text is retained from upstream. RTL, control, testbench,
independent Berlekamp factorization oracle, exhaustive small-domain check,
fixtures, timing analysis and runner are authored locally.

No SymPy import, network access or unknown sibling source is required by the
production core or its offline finite checks. The scalar timing/reset schedule
analysis is identified separately from the numeric factorization oracle.
