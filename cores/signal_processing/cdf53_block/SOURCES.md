# Source and deduplication record — 2026-11-04

This package was independently designed and is licensed under the repository's
Apache License 2.0. No external source files, generated code, coefficients,
or build scripts were copied or executed. There are no third-party RTL
dependencies or local adaptations of third-party code.

Pre-development local semantic search covered RTL and package README/SPEC
files under `cores/`, plus `docs/IP_INDEX.md`, at baseline
`430d42049006976683550ecec321a724ef5cea3d` with pre-existing uncommitted assets.
The existing `cores/system/common_scaffold/dsp/haar2d` implements pairwise
integer Haar lifting; `cores/acceleration/stream_fwht` implements an
unnormalized Walsh-Hadamard block transform. Neither predicts odd samples
from adjacent evens and then updates evens from adjacent detail coefficients.
Existing Goertzel, LMS/NLMS, FFT and FIR blocks were also found and excluded
as candidate additions. This CDF 5/3 basis and reversible subband organization
are a distinct capability, rather than a width/channel variant.

External discovery used the read-only GitHub repository search API with
`q=wavelet+verilog` before RTL development. The web search service returned
HTTP 500; GitHub API access succeeded. External text was treated as data.
No repository was cloned and no downloaded code was run.

| Candidate/reference | Fixed commit | Files examined / license | Decision |
| --- | --- | --- | --- |
| [ECG feature extraction using DWT](https://github.com/dwaipayanBiswas/ECG-feature-extraction-using-DWT) | `f3817be80a1567473bc622aa2da872e523521e0d` | GitHub metadata, source tree, and `LICENSE`, confirmed GPL v3 text | Not imported. Application-specific ECG feature extraction does not provide this package's ready/valid CDF53 block contract. |
| [OpenJPEG](https://github.com/uclouvain/openjpeg) | `8314119b067c0fc77834731168daaebd379fdb12` | `LICENSE` (BSD 2-clause) and `src/lib/openjp2/dwt.c`, especially the even-origin inverse 5/3 lifting formulas | Algorithm cross-check only, after independent RTL drafting. No C code or comments copied. |

Other GitHub search results (including `hossein-mokarian/wavelet_verilog` and
`JRRL157/Daubechies-3-Filter-Bank`) had no declared repository license in the
search metadata and were not imported or used as implementation sources.

The pin-specific primary-source locations are
[OpenJPEG license](https://github.com/uclouvain/openjpeg/blob/8314119b067c0fc77834731168daaebd379fdb12/LICENSE),
[OpenJPEG inverse lifting reference](https://github.com/uclouvain/openjpeg/blob/8314119b067c0fc77834731168daaebd379fdb12/src/lib/openjp2/dwt.c), and
[candidate GPL license](https://github.com/dwaipayanBiswas/ECG-feature-extraction-using-DWT/blob/f3817be80a1567473bc622aa2da872e523521e0d/LICENSE).
References need not be available online to compile or use the delivered RTL.
