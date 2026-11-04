# B12 semantic and pinned-source preflight - 2026-11-04

Baseline: `d35ce742b34ffa7afebffe0b9f6705a825f469e1` (published B11).
Actual production semantic searches and the approved contract/architecture
brief preceded the new RTL. Searches of production RTL, README and SPEC content
for KS, Kolmogorov, Smirnov and two-sample CDF-distance services found no
equivalent implementation.

Actual nearby sources were read: `mann_whitney_u` returns pairwise win/loss/tie
populations, U statistics and an effect ratio rather than the two-CDF supremum.
`stream_histogram_rank` scans a single population for rank/median queries.
The actual CDF accumulation and LUT mapping sections of
`dsp_isp_library/isp/histeq/rtl/histeq_stream.sv` implement single-image HE/CLAHE
mapping. Neither compares two normalized distributions. CDF53 search matches
are wavelet naming; the bilateral filter's `cdf` is a delayed center sample.
This package adds a distinct mathematical service. No older package is edited.

## Actual fixed source and complete license inspection

[SciPy](https://github.com/scipy/scipy), v1.15.2 fixed commit
`0f1fd4a7268b813fa2b844ca6038e4dfdf90084a`. Read-only GitHub contents API
requests returned complete base64 byte payloads; both were decoded as strict
UTF-8. The actual `ks_2samp` implementation body and complete BSD3 license were
read. Each HTTPS request had a 15-second timeout.

| File | Git blob | Bytes | SHA256 |
| --- | --- | ---: | --- |
| [LICENSE.txt](https://github.com/scipy/scipy/blob/0f1fd4a7268b813fa2b844ca6038e4dfdf90084a/LICENSE.txt) | `117117616e806a9bb960b1f32a552c8c912b0497` | 1536 | `c29fb8e5936f33237a8b15256b4c6e93037f05bbf58c3d7b5755aede4c200173` |
| [scipy/stats/_stats_py.py](https://github.com/scipy/scipy/blob/0f1fd4a7268b813fa2b844ca6038e4dfdf90084a/scipy/stats/_stats_py.py) | `4b8c1850cd0dad3d654216ae45dad04dafaa983b` | 417517 | `01b665feba503fd53684d00ca6f322550fa41d414e09da482ab97f48d64b8a5b` |

The complete license names Enthought and SciPy Developers, requires retained
notices, conditions and disclaimer, and restricts endorsement. The source sorts
raw sample arrays, queries empirical CDFs with `searchsorted(side='right')`,
and derives signed minimum/maximum differences, distance, location and sign.
Its exact/asymptotic p-value machinery is separate and excluded here.

The local input is already aligned sorted integer-frequency bins. The local
datapath uses exact bounded totals, synchronous replay RAM and a shared serial
integer multiplier; the source uses floating array operations. Opposite-sign
equal maxima select the positive side in SciPy, whereas this contract selects
the earliest supplied key. A local zero distance has direction zero and the
first kept witness. There is no API, floating-point, bitwise or tie-location
compatibility claim.

No upstream implementation, source, comments, tests, license text or build code
was copied, adapted, translated, executed or redistributed. Retrieved bytes were
untrusted reference text only: nothing was imported or run and no download was
persisted. New RTL, wrapper, independent oracle, testbench, runner and prose are
original repository Apache-2.0 work under root [LICENSE](../../../LICENSE) and
[NOTICE](../../../NOTICE). Offline operation needs no SciPy, third-party runtime,
generated data, vendor primitive, sibling source, submodule or network. The
dependency list is explicitly empty. The old untracked `fraction_compare` is
untouched and excluded.
