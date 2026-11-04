# Semantic and fixed-source preflight

Baseline: published B22 `20e2db4aded8858ff63e132c2399fb416aa48ed0`.
Before any local RTL, the whole cores tree was searched for binomial,
binomial_coefficient, n_choose_k, nCr, combinadic, factorial, math.comb and
Chinese combination/coefficient terms. Hits were fixed filter kernels, CIC
models, polygon-shape helpers and factorial determinant-oracle bounds. No
production runtime scalar exact binomial service was found. Complete actual
contracts of budget_knapsack, integer_polynomial_resultant, integer_divider,
stream_prefix_sum32 and affine_floor_sum were read. They optimize selected
items, eliminate polynomials, divide one integer pair, accumulate actual values
modulo32, or analytically sum affine quotients. None counts all K-subsets of
an N-element set from two runtime integers. Pascal storage shares a general DP
idea with knapsack but has a different input, invariant and result contract.

The following complete untrusted upstream source was fetched, strictly UTF8
decoded, hashed and read without truncation before original HDL:

- Boost.Math tag `boost-1.88.0` resolves directly through the GitHub git/ref API
  to `529f3a759d83aa9437613666ea6293c9336d4069`.
- [binomial.hpp](https://raw.githubusercontent.com/boostorg/math/529f3a759d83aa9437613666ea6293c9336d4069/include/boost/math/special_functions/binomial.hpp):
  2997 bytes, SHA256 `a3ab37b3f0b14f76f66f7cabceed7299f2f7e75c08284238388489bad1ad9df5`.
  All templates, branches, float specialization, includes and license header
  were read. It computes floating factorial/beta values then rounds, excludes
  integral result types and rejects K>N. These differ from the local contract.
- The math subrepository root license URL returned404. The fixed parent Boost
  same tag resolves directly to `199ef13d6034c85232431130142159af3adfce22`.
  GitHub contents API for that commit's `libs/math` explicitly identifies the
  submodule as `529f3a759d83aa9437613666ea6293c9336d4069`.
- [Complete parent LICENSE_1_0.txt](https://raw.githubusercontent.com/boostorg/boost/199ef13d6034c85232431130142159af3adfce22/LICENSE_1_0.txt):
  1338 bytes, SHA256 `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566`.
  The complete Boost Software License1.0 grant, required notice retention and
  warranty/liability disclaimer were read. Source copyright: John Maddock2006.

Only read-only HTTPS metadata/source inspection occurred. No upstream source,
comments, tests or license text were copied, adapted, saved locally or executed.
The local nine-state addition-only Pascal RAM engine, independent factorial
oracle, fixtures, TB, runner and docs are original Apache-2.0 work under the
repository LICENSE/NOTICE. There is no adopted Boost implementation, dependency,
floating-point behavior or compatibility claim.

MATRIX_FREEZE.json, all exact input/result fixtures, all child partitions and
all reset targets were frozen before any original HDL. SOURCE_FREEZE.json binds
the final complete source set before the first compiler. One local production
source and the complete default/maximum example need no includes, generated
images, vendor blocks, sibling sources, external memory or network.
