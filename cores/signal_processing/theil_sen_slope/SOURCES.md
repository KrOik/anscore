# B11 semantic and fixed-source preflight - 2026-11-04

Baseline: `c778301aa12d1b9bf4290b1a982f4c6325713fcd` (published B10).
Actual semantic searches and the contract/architecture brief preceded new RTL.

Production RTL/README/SPEC searches covered Theil/Sen, pairwise/median slopes,
robust slope and Chinese slope terminology across numerical, acceleration,
image, storage and system areas. No equivalent service was found. Actual
`stream_linear_fit` RTL/README was read: it accumulates ordinary least-squares
normal equations and returns quantized slope/intercept. The stable
`stream_frame_sort` returns integer-key records and ranks, without generating,
orienting or comparing rational point-pair slopes. PAVA fits ordered monotonic
block means; Mann-Whitney returns two-group rank statistics. These are distinct
mathematical services, not a width or handshake variant of this estimator.

The old `fraction_compare` is untracked, as verified with `git ls-files`; it is
neither promoted, copied, edited nor depended on. This package independently
implements signed-by-positive shift/add products to order exact slopes. All
production source is local, and the dependency list is explicitly empty.

## Actual pinned source and complete license inspection

[SciPy](https://github.com/scipy/scipy), fixed v1.15.2 commit
`0f1fd4a7268b813fa2b844ca6038e4dfdf90084a`.
The web endpoint returned HTTP500; direct read-only GitHub contents API reads
then succeeded. Both complete byte payloads were base64-decoded as strict UTF-8,
the actual `theilslopes` function body and complete BSD 3-clause license were
read before implementation. Each HTTPS read had a 15-second timeout.

| File | Git blob | Bytes | SHA256 |
| --- | --- | ---: | --- |
| [LICENSE.txt](https://github.com/scipy/scipy/blob/0f1fd4a7268b813fa2b844ca6038e4dfdf90084a/LICENSE.txt) | `117117616e806a9bb960b1f32a552c8c912b0497` | 1536 | `c29fb8e5936f33237a8b15256b4c6e93037f05bbf58c3d7b5755aede4c200173` |
| [scipy/stats/_stats_mstats_common.py](https://github.com/scipy/scipy/blob/0f1fd4a7268b813fa2b844ca6038e4dfdf90084a/scipy/stats/_stats_mstats_common.py) | `6900eba1fa6157c9de956255c49f5cbce0029c11` | 11557 | `f5215bcd404e7fa4294f00a2464c97225280966e81f6e0bc96ffd55d2b223f3a` |

The license names Enthought and SciPy Developers, requires retention of notices,
conditions/disclaimer and restricts endorsement. The source takes slopes where
deltax>0 and uses their median. Its intercept conventions and confidence-interval
inference are additional outputs outside this core's contract. This original
implementation uses exact integer fractions and a serialized RAM sorter rather
than floating arrays, vectorized differences or an upstream sorting routine.

No upstream implementation, source, comments, tests, license text or build code
was copied, adapted, translated, executed or redistributed. The downloaded bytes
were untrusted reference text only; nothing was imported or run, and no download
was persisted. There is no SciPy API, floating-point or bitwise compatibility
claim. New RTL, wrapper, independent oracle, tests, runner and prose are original
repository Apache-2.0 work under root [LICENSE](../../../LICENSE) and
[NOTICE](../../../NOTICE). Offline users need no third-party runtime, generated
table, vendor primitive, sibling source, submodule, network or remote build.
