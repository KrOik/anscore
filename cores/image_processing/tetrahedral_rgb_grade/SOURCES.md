# Deduplication and provenance

Baseline B44: `09de72c578b3099d4e867c739118faa7607f663d`.

Read-only semantic search included indexed and unindexed RTL under `cores`,
`assets`, `components` and `systems`, including common_scaffold, extended_library,
operator_library and dsp_isp_library. Existing image packages and active source
boundaries were inspected rather than relying on module-name differences.

The nearest existing implementation is
`cores/system/common_scaffold/image/color_lut3d/color_lut3d.v`: complete
endpoint-aligned trilinear interpolation, one frame-safe table, eight serial
vertex reads, a bit-serial arithmetic engine and restoring divider. Its README,
RTL and STATUS were read without running its tests or synthesis scripts.
The new design has distinct tetrahedral interpolation, four-vertex traversal,
three pipelined shared products, exact divider-free normalization, and a second
table allowing frame-overlapped load with command-boundary publication. A cube
containing nonlinear cross terms generally gives different outputs under these
two interpolation rules. Existing lens shading interpolates 2D CFA gain meshes;
indexed_texture_sampler interpolates 2D texture samples. Neither implements this
3D color operation or publication protocol. Existing gamma/AWB/CCM, median,
line filters, error diffusion and RGBA primitives are not duplicated.

External technical reference was inspected read-only at OpenColorIO v2.4.2,
commit `6918fad3f5d22ac3ef2397c754bf4268c2b58dd0`:

- `src/OpenColorIO/ops/lut3d/Lut3DOpCPU.cpp`: SHA256
  `405733918dbe15ac54a486c275bf6f68b699b241f357431a7ce8db7afa80224f`,
  58,902 bytes. Its scalar tetrahedral branch and interpolation dispatch identify
  the four-node decomposition and six possible fraction orders.
- `LICENSE`: SHA256
  `82a40c52065ee968aa62015735e84378ac11425db7a233e6a2dcd2c83fc24276`,
  1,485 bytes, BSD-3-Clause; copyright OpenColorIO contributors.

No external code, build scripts or generated data were copied, imported or
executed. The integer RTL and Fraction oracle are authored independently. The
new authored material is Apache-2.0, using the repository LICENSE. The only RTL
dependency is the unchanged local isp_rgb2gray module, copied as exact bytes
into the finite executed-source archive if/when authorized; no old evidence is
inherited as qualification of the new composition.
