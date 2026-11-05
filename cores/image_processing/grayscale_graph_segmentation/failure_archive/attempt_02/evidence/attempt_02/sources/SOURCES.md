# Search, reuse and source provenance

Author-draft baseline is the published B27 source closure. This package is a
new pixel-to-region service; existing source and historical evidence are not
modified or requalified.

Actual read-only semantic inspection covered `cores/image_processing`,
`cores/system/common_scaffold/image`, `common_scaffold/signal_video`,
`cores/signal_processing/dsp_isp_library/isp`, `extended_library/ip`, the B27
manifest and production README/RTL names/content. No FH/Felzenszwalb/
Huttenlocher implementation was found. Important exclusions were:

- common_scaffold/image/thinning: complete iterative Zhang-Suen thinning.
- watershed: actual marker-controlled priority flooding.
- kmeans_segmentation/lab_kmeans_quantizer: color-vector clustering/quantization.
- block_motion/optical_flow/stereo_census/stereo_sgm: existing motion/stereo.
- jpeg_gray_decoder/jpeg_color_decoder/png_decoder/tiff_decoder: actual
  compressed-byte parsers and reconstruction, including full PNG DEFLATE.
- image_processing/grayscale_max_tree: upper-component parent/area hierarchy.
- grayscale_area_opening: connected bright-structure filtering.
- connected_components/CCA: connectivity under supplied foreground/labels.

The new graph predicate adapts to current component internal edge evidence and
area without markers, prelabels, color centers or a host graph.

## Primary mathematical reference

Pedro F. Felzenszwalb and Daniel P. Huttenlocher, *Efficient Graph-Based Image
Segmentation*, International Journal of Computer Vision59(2),2004.

- Author page actually read: https://cs.brown.edu/people/pfelzens/segment/
- Author PDF actually read in memory,26 pages:
  https://cs.brown.edu/people/pfelzens/papers/seg-ijcv.pdf
- Author software ZIP actually inspected in memory:
  https://cs.brown.edu/people/pfelzens/segment/segment.zip
- Inspected entries included README, COPYING, segment-graph.h, segment-image.h
  and disjoint-set.h. The headers declare2006 Pedro Felzenszwalb and
  GPL version2 or later; COPYING contains GPLv2.

The external C++ software is reference-only. No code is copied, translated,
adapted or redistributed. Its Gaussian-smoothed RGB graph and floating-point
implementation are not claimed as a bit-identical reference for this raw
integer grayscale four-neighbor contract. The independent RTL implements the
paper's predicate with exact cross products, a serialized stable counting sort
and the project's pre-existing synchronous DSU. The independent Python model
uses explicit member sets, a software tuple sort and Fraction arithmetic.
Tie ordering, canonical minimum-member labels, exact min-size postpass and
stream/error semantics are explicitly specified by this package.

The alternative JPEG-LS direction was screened through the JPEG committee's
official https://jpeg.org/jpegls/index.html overview. ITU/CharLS retrieval was
unavailable in that precheck; it was not selected and adds no dependency.
No external installation, build, generator or test script was executed.

## Reused local RTL

`cores/acceleration/disjoint_set_union/rtl/disjoint_set_union.sv`

SHA256 `a80d32edd4a02186e698ba62053ad2d9794b2a76c35cf8518dc3af46e67cc3ad`.
Its existing Apache-2.0 source is referenced directly through files.f, never
patched or duplicated. The B27 manifest SHA and source binding are recorded in
DEPENDENCIES.json. No inherited numerical matrix/checker is run. Its rank winner
contract and public returned UNION representative are used without assuming
that representative equals the component's minimum pixel address.

All new RTL, TB, model, runners, recipes and prose are original Apache-2.0.
The complete license accompanies this package. No third-party RTL, ROM,
generated upstream output or downloaded source is part of production closure.

Process-tree control follows Windows Job Object / process creation / Toolhelp
APIs; no external helper program is installed. Relevant platform documentation:
https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects
and https://learn.microsoft.com/en-us/windows/win32/toolhelp/traversing-the-thread-list.
