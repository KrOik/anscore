# Read-only upstream review and independent implementation

Before the first local RTL edit, the complete CPython `Lib/fractions.py`
(38,147 bytes) and complete root `LICENSE` (13,936 bytes) were fetched and
read as untrusted text. No upstream code was executed, imported, copied,
translated or adapted into this package. No upstream runtime dependency.

- Repository: https://github.com/python/cpython
- Release: v3.12.8. Annotated tag object
  `3a523043165785601895d7cdc74713dfa64d630d` resolves through the GitHub
  git/tags API to commit `2dc476bcb9142cd25d7e1d52392b73a3dcdf1756`.
- Complete source:
  https://github.com/python/cpython/blob/2dc476bcb9142cd25d7e1d52392b73a3dcdf1756/Lib/fractions.py
  SHA256 `d52d1ab9d5be26924e4914a5e40069c992bbfa68f773694c2e5ee8452d0766a0`.
- Complete license:
  https://github.com/python/cpython/blob/2dc476bcb9142cd25d7e1d52392b73a3dcdf1756/LICENSE
  SHA256 `3b2f81fe21d181c499c59a256c8e1968455d6689d269aa85373bfb6af41da3bf`.
  Python Software Foundation License v2, with BeOpen, CNRI, CWI and
  documentation Zero-Clause BSD historical/associated terms, all read.
  Source credits Sjoerd Mullender and Jeffrey Yasskin. These references
  convey attribution for technical reading; the new code uses the root
  Apache-2.0 license and NOTICE and contains no incorporated Python source.

`Fraction.limit_denominator` specifies nearest bounded-denominator rational
approximation and explains convergents/semiconvergents. The local RTL instead
walks Stern-Brocot adjacent fractional bounds using residual subtraction.
Its sign-symmetric integer-half tie rule intentionally differs from CPython's
floor-on-equal-denominator rule for negative halves. The independent oracle
enumerates every allowed denominator and adjacent integer numerators; it
does not call `limit_denominator` or reproduce the RTL bound search.

Semantic deduplication at baseline `ff2aadf8ebdc8e5475b7022cd68d47e496b9f593`:
all 76 snapshot package names/contracts were inspected, and the complete
`cores` tree was searched for bounded-denominator approximation,
limit_denominator, continued fractions, Farey and Stern-Brocot. One generic
"without approximation" sentence in Kendall tau was the only text hit.
Existing resamplers, integer/fixed-point division, exact rational linear
algebra and rational polynomial interpolation neither choose an optimal
runtime denominator nor implement this rational projection service.
This package plans a ratio; it does not perform sample filtering or division
of a sample stream. Production closure is one local RTL file, with no sibling,
ROM, fixture, coefficient, generated-source, network or vendor dependency.
