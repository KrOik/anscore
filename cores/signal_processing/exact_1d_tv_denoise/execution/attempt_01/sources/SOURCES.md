# Sources and independent derivation

Original RTL, fixed analytic fixtures, certificate checker and TB in this package are Apache-2.0. The objective is the standard one-dimensional unweighted TV denoising/proximal problem. The original mathematical derivation in MATHEMATICS.md constructs and proves a scan of feasible slopes in the cumulative dual tube, with exact rational integer arithmetic and a separately derived serialized FSM.

Primary attribution: Laurent Condat, A Direct Algorithm for 1-D Total Variation Denoising, IEEE Signal Processing Letters 20(11), 1054-1057 (2013), DOI https://doi.org/10.1109/LSP.2013.2278339. The author publications page is https://lcondat.github.io/publications.html and lists https://lcondat.github.io/publis/Condat-fast_TV-SPL-2013.pdf. The bibliographic record and author page were read; the PDF was not read. No paper-specific theorem numbering or quotation is claimed.

Author C implementations at https://lcondat.github.io/download/condat_fast_tv.c and https://lcondat.github.io/download/Condat_TV_1D_v2.c were previously read as text for scope, algorithm-family and license awareness. Their CeCILL code is not copied, translated line by line, included, loaded or executed here. The package implementation follows the independent KKT/tube proof rather than those programs. Author-code checksums and the exact reading boundary are retained in the external B29 candidate brief.

The exact certificate checker uses Python's standard-library Fraction only for the ten frozen analytic targets and the four specified fresh reset replays. It neither searches input alphabets/sign partitions nor shares the RTL's scan recurrence. There is no inherited numerical matrix.

sim/process_tree.py is reused verbatim from Anscore's Apache-2.0 grayscale_graph_segmentation/process_tree.py for suspended Windows Job Object process-tree supervision; this is tooling reuse, not mathematical/reference reuse. Tool binaries, runtime DLLs and VPI modules remain external and must be fingerprinted and independently reviewed by the future preparation seal. They are not redistributed as package sources.
