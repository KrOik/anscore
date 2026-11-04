# Source and license record

Production RTL, protocol, finite-width architecture, examples, fixtures, testbench and runner were independently authored for this package. They are Apache-2.0. No upstream implementation is imported or executed in generation, production or qualification.

The algorithm reference is the existing installed **SymPy 1.14.0** distribution under `C:/Users/29668/.codex/tools/mcp-ffmpeg/.venv/Lib/site-packages/`. Reading used file bytes and Python standard-library metadata only. Complete installed METADATA/release.py and the applicable 153-line license were read. Installed RECORD hashes and byte counts independently matched the source bytes.

| Read reference | Bytes | SHA256 |
|---|---:|---|
| sympy/polys/matrices/dense.py, complete824 lines | 23,217 | 4587688151de599a1e3bde0e6a5d667f5b09be3f899b24bf6da462f3e77d466b |
| sympy/matrices/determinant.py | 34,550 | a434c36022c1496268bff8ff07e6591dda87dfe590feec2165ac2b5f710313d9 |
| sympy/release.py | 23 | a22b5a9a2b182e9de5ac5237b86bfee5908921e60e4fd8192dcb3352654d870f |
| distribution METADATA | 12,816 | b756c2fbfd5be05ac5bdb0ebca61f55618f30f633ed92d88a5687429313a7595 |
| complete LICENSE, retained as LICENSE.SYMPY | 7,885 | 07a5e9819f727b4986ad2829c7a29a6320d42575f720eb24d71b7fef573a0286 |

The complete dense `ddm_berk` and its `ddm_imatmul` helper were read in the full file. The complete `DDM.charpoly` wrapper was also read. Current dispatch was checked: `determinant._charpoly -> DomainMatrix.charpoly -> SCC block factors -> charpoly_base -> charpoly_berk -> rep.charpoly`. Density selects dense or sparse representation, and integer ZZ needs no denominator clearing. The dense wrapper calls `ddm_berk`; the historical `determinant._berkowitz_vector` is not the current direct charpoly route.

Published source locator: https://github.com/sympy/sympy/tree/sympy-1.14.0 . Previously verified annotated tag `2f9c274d2021b5a43de627f703d3a8f8955a1038` peels to commit `16fa855354eb7bcabd3fe10993841e03b1382692`. Installed determinant.py and LICENSE hashes match those previously remotely verified fixed files. **dense.py provenance is the installed release, RECORD and exact hash; it was not independently freshly hashed against the remote commit.** Failed read-only network attempts were not used to claim remote verification. No upstream algorithm was run.

The complete BSD license and all bundled appendices are retained without abbreviation. Reference concepts are block partition, vector-power Toeplitz first column and coefficient convolution; the RTL storage schedule, signed widths, bounded shift/add engine and streaming frame contract are new independent work.

Actual adjacent RTL was read for `symmetric_eigen2x2`, `linear_solve2x2`, `integer_polynomial_resultant`, `exact_binary_permanent`, `binary_linear_recurrence`, `nonnegative_least_squares2` and `rational_polynomial_interpolate`. None exposes the complete characteristic polynomial of an arbitrary runtime signed integer square matrix. Fixed GF(2) scrambler tap polynomials also do not provide this service.
