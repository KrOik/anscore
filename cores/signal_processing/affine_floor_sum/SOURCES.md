# Sources and originality

Capability: exact analytic unsigned affine floor sum. Existing cores were searched
for floor sums, lattice counts and arithmetic progressions before implementation.
Complete reads of stream_prefix_sum32 SPEC/RTL, integer_divider README/RTL,
signed_divider README and integer_gcd README confirmed different services: actual
stream modulo prefix sums, one quotient/remainder, signed truncation or GCD.
No existing local analytic floor-sum service was found. A local W-divisor serial
unit avoids a wider general divider dependency. Production has one local source.

Before original RTL, complete upstream files were fetched, strictly UTF-8 decoded
and read without truncation. No source was imported, executed or adapted:

- Repository: https://github.com/atcoder/ac-library
- Fixed v1.6 lightweight tag commit: `864245a00b00dd008d1abfdc239618fdb7d139da`
- Tag evidence: https://api.github.com/repos/atcoder/ac-library/git/ref/tags/v1.6
- [math.hpp](https://raw.githubusercontent.com/atcoder/ac-library/864245a00b00dd008d1abfdc239618fdb7d139da/atcoder/math.hpp),
  2801 bytes, SHA256 `ddb92d513c1e0b1eb5bdb5479e6c697aa3b37da8a753cd9ec6102af27d389f68`.
- [internal_math.hpp](https://raw.githubusercontent.com/atcoder/ac-library/864245a00b00dd008d1abfdc239618fdb7d139da/atcoder/internal_math.hpp),
  5684 bytes, SHA256 `487416d11ce878d7785559a02c84f094529e39fa5cc593d4c45e91fc7da53f56`.
- [LICENSE](https://raw.githubusercontent.com/atcoder/ac-library/864245a00b00dd008d1abfdc239618fdb7d139da/LICENSE),
  6554 bytes, SHA256 `5537d4d10b76b81b6e8dfd8b644480a4b1efa332fbb0cdb61126c5be781ef7b4`.

The full CC0 1.0 Universal purpose, rights, waiver, fallback and limitations were
read. The mathematical Euclidean floor-sum identity informed the architecture.
Upstream uses a modulo-64 aggregate and signed wrapper; this original RTL uses a
bounded unsigned exact 3W-bit contract and a distinct serial schedule. Local RTL,
example and testbench are Apache-2.0. No upstream code is distributed or required.
The independent expected-data oracle directly enumerates the defining sum and
does not use the Euclidean recurrence. Scheduling metadata and trace validation
may use the identity but never supply the expected output sum.

MATRIX_FREEZE.json and twelve fixtures were frozen before any original HDL was
written. SOURCE_FREEZE.json binds the eventual complete source and test closure
before the first compiler child. All qualification is finite and offline.
