# Scope, semantic deduplication and provenance

Baseline: da85338f8a22c454cce77f5b88dd7a803975deb6 (B25 release). Goal and
protected original worktree assets are unchanged. Git and shared documentation
are owned by root. B25 qualification is never rerun by this package.

The100 cumulative package objects and existing DSP/acceleration production
RTL/README/SPEC files were searched for irreducibility, Rabin, Ben-Or,
squarefree, binary polynomial arithmetic, matrix rank and linear recurrence.
Existing polynomial_mod_mul/mod_pow/divmod/inverse/eval explicitly do not test
irreducibility. Inverse tests one element for being a unit even in a reducible
quotient ring. GF(2) rank/solve and finite-sequence Berlekamp-Massey provide
different outputs. Integer characteristic polynomials, resultants and real-root
counts operate on different domains and do not classify this runtime P.

The existing modular multiplier and inverse were read completely. Their
production files are original protected UNTRACKED assets, absent from the
B25 committed tree; they are not a legal committed closure dependency here.
They are neither modified, staged, copied nor executed. This new package uses
only its own small square and GCD-remainder datapaths, with no Bezout/inverse
state and no additional standalone duplicate arithmetic IP.

External pre-implementation source review (read only; no remote code executed):

- Repository: https://github.com/sympy/sympy
- Release1.14.0 resolves through the official GitHub API to commit
  fe935ceb303891d1f8bea4c03b19fd9ec9464b02.
- File sympy/polys/galoistools.py, Git blob
  b09f85057eced59b8054c6007f2b291a35a2fafb,57238 bytes,
  SHA256 67779dfc0d0da218fd473b8cde4a26efe6b2e0c9f3207a69c2057642938db93a.
- Complete gf_irred_p_ben_or lines1430-1472 and gf_irred_p_rabin lines1475-1516
  were inspected. They establish the finite-field checkpoint algorithm;
  list-polynomial arithmetic, Python factorint and Frobenius helper code are
  not imported, copied or required at runtime.
- Complete upstream LICENSE, Git blob
  0744f229d697ca3ed1b1b257bfdb70e3eecf0b9e,7885 bytes,
  SHA256 07a5e9819f727b4986ad2829c7a29a6320d42575f720eb24d71b7fef573a0286,
  was read before implementation and is retained as LICENSE.SYMPY. The relevant
  SymPy notice is BSD three-clause; the complete file also preserves unrelated
  bundled notices rather than truncating the upstream license record.

Official source/metadata were fetched in memory through the GitHub API at the
fixed commit. The initial web service failed and default-proxy raw requests
timed out; the successful explicit direct API retrieval supplied the hashes
above. No unknown installer, project script or SymPy import was executed.

Local RTL, wrapper, TB, Berlekamp/derivative primary oracle, independent full
square/long-remainder Rabin implementation, factor enumeration, fixtures and
finite runner are authored here. The scalar GCD reset/latency analysis is
explicitly separate from the arithmetic oracle. No library dependency,
network access, source generation or untracked sibling is required to use RTL.
