# Source and license preflight

Baseline: `fcd2beef77f998da54801b91d74ce47946bee17c`.

## Actual semantic de-duplication before RTL

Repository-wide filename/content searches for distance transform, Manhattan,
chessboard, GLSZM, gray/grey-level size zone and equal-gray components were
performed before creating this package. Actual contracts and relevant source
ports/decisions were inspected for:

- `cores/system/common_scaffold/image/distance_transform`: exact L1/Linf
  foreground-to-background maps; rejected as already available.
- `.../connected_components`: one-bit foreground CCL with raster labels and
  component area/bbox, not all-gray zones or their size-frequency matrix.
- `cores/image_processing/grayscale_area_opening`: repeated upper-level-set
  filtering, not equal-gray maximal components.
- `.../common_scaffold/image/glcm`: neighbor co-occurrence counts.
- `cores/image_processing/streaming_glrlm`: directional maximal linear runs.

No existing matrix counted whole connected equal-gray regions by gray and size.
Changing connectivity alone would not justify a new IP; the new capability is
the complete gray-level zone-size distribution, including zero-valued regions.

## Fixed implementation inspected before RTL

Repository: <https://github.com/AIM-Harvard/pyradiomics>

Immutable commit: `08bea7067e350303eead533b471aa60697b3b8c3` (v3.0.1 tree).
Actual decoded bytes were fetched read-only directly from this fixed commit;
no external build/install, import or execution was performed. Complete
`calculate_glszm` and `fill_glszm` C bodies were read, together with the Python
mathematical class and `_calculateMatrix` code, and the entire license.

| File | Bytes | Git blob | SHA-256 |
| --- | ---: | --- | --- |
| [LICENSE.txt](https://github.com/AIM-Harvard/pyradiomics/blob/08bea7067e350303eead533b471aa60697b3b8c3/LICENSE.txt) | 1467 | `62155cc735f5f9e214307a8d880643c2ccfc860d` | `5c1fc504fb0865a72a29e035b25ef3513e6d7e9c7169cb445eae855f03b006e2` |
| [radiomics/glszm.py](https://github.com/AIM-Harvard/pyradiomics/blob/08bea7067e350303eead533b471aa60697b3b8c3/radiomics/glszm.py) | 14747 | `e096a8f974ecc1f274d2dbc3226def49bd0ebc49` | `ff039eb01a5183371760c07b8875f6501c09b2a2185b23ff4eb352b33f882260` |
| [radiomics/src/cmatrices.c](https://github.com/AIM-Harvard/pyradiomics/blob/08bea7067e350303eead533b471aa60697b3b8c3/radiomics/src/cmatrices.c) | 36445 | `f90434ccbb72ce9001104df5e48074d25c87277c` | `3e5d49381d5acaac813685a74199b6614e0731687b27905c058eed1df16a2070` |

Copyright 2017 Harvard Medical School. The complete inspected BSD 3-Clause
license permits source/binary redistribution with retention of the copyright,
conditions and disclaimer, and prohibits endorsement using holder/contributor
names without permission. Its full warranty/liability disclaimer was read.
License decision: permissible mathematical/behavioral comparison. No upstream
implementation, docstring, script or license file is copied into this package;
new independently written RTL/tests/docs use root Apache-2.0 LICENSE/NOTICE.
The third-party runtime dependencies NumPy, six and radiomics are not imported
or included. Upstream data were inspected in memory, not retained as assets.

Upstream counts equal-gray connected voxels inside an ROI using an angle-driven
LIFO region grower, then increments a positive-gray size matrix from temporary
zone records. The 2D default uses 8-connectivity, positive binned gray indices,
and removes empty gray/size rows/columns in the feature layer. This implementation
instead has the full rectangle, MSB quantization with gray0 retained, static
4/8 connectivity, fixed dense gray/size output including all zero bins, a FIFO
and explicit hardware marker/reset/ready-valid rules. No PyRadiomics API,
feature-value, clinical or standardized medical compatibility is claimed.

The independent oracle uses global undirected edge union and root-size
aggregation, rather than either upstream LIFO growing or the RTL FIFO traversal.

## Offline closure

Production manifest contains one local RTL source. The example adds one local
wrapper; no sibling RTL, generated ROM, initialization file, external RAM,
vendor IP, internet access or Python package is required to elaborate it.
The test runner uses only the Python standard library and local Icarus tools.
Root LICENSE/NOTICE are preserved; numerical/physical evidence cannot be
inherited from the older image-processing library.
