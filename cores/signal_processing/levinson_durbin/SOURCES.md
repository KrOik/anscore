# Originality and source search — 2026-11-04

Baseline: ba0b98f, the preceding stable integration batch. Repository-wide
RTL/README/SPEC and IP-index searches for Levinson, Durbin, Burg, LPC
coefficient estimation and linear prediction found no equivalent estimator.
Existing Goertzel, FIR, LMS/NLMS, CDF53, polynomial/Farrow interpolation and
generic 2x2 solve were considered and excluded as duplicate directions.
No existing source or prior evidence was modified.

External predevelopment search used the read-only GitHub repository API with
`q=levinson+durbin+verilog`; it returned no candidate repository. Two mature
software sources were then inspected as technical references, never as agent
instructions. No upstream code/build scripts were executed or copied.

| Reference | Fixed revision | Inspected files and decision |
| --- | --- | --- |
| [SciPy v1.14.1](https://github.com/scipy/scipy) | `92d2a8592782ee19a1161d0bf3fc2241ba78bb63` | `LICENSE.txt` and `scipy/linalg/_solve_toeplitz.pyx`, retrieved through GitHub contents API. LICENSE is BSD 3-clause, copyright 2001-2002 Enthought and 2003-2024 SciPy Developers. The Toeplitz implementation identifies Robert T. McGibbon and an Alan Miller public-domain algorithm reference. Used to compare the general Levinson/Toeplitz/reflection interpretation; no implementation text copied or translated. Its floating/complex system solver is not this package's fixed-point LPC contract. |
| [SpeexDSP](https://github.com/xiph/speexdsp) | `7a158783df74efe7c2d1c6ee8363c1e695c71226` | Actual `COPYING` was read and has BSD 3-clause conditions with named Xiph/Jean-Marc Valin/other contributors. A request for `libspeexdsp/lpc.c` returned 404. No LPC implementation was obtained or used. A separate Speex metadata request timed out and was abandoned. |

Pin-specific primary links:
[SciPy license](https://github.com/scipy/scipy/blob/92d2a8592782ee19a1161d0bf3fc2241ba78bb63/LICENSE.txt),
[SciPy Toeplitz reference](https://github.com/scipy/scipy/blob/92d2a8592782ee19a1161d0bf3fc2241ba78bb63/scipy/linalg/_solve_toeplitz.pyx),
[SpeexDSP license](https://github.com/xiph/speexdsp/blob/7a158783df74efe7c2d1c6ee8363c1e695c71226/COPYING).

The RTL, example, deterministic test generator and documentation are original
and use the repository Apache License 2.0. No third-party source, generated
RTL, coefficient table, local adaptation or transitive runtime dependency is
redistributed. The delivered source closure works without network access.
