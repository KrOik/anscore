# Offline source closure and provenance

The core file list is `files.f`. The actual dual sampler composition file list is `example/files.f`, interpreted from this package directory. All required RTL is resident in the repository:

| Source | Role | Origin |
| --- | --- | --- |
| `rtl/rgba_porter_duff.sv` | 13-mode premultiplied RGBA core | New independent Apache-2.0 RTL |
| `rtl/rgba_pair_premultiply.sv` | Atomic straight-pair conversion | New independent Apache-2.0 RTL |
| `example/dual_indexed_porter_duff.sv` | Owned dual lookup/conversion/composition | New independent Apache-2.0 wrapper |
| `../indexed_texture_sampler/rtl/indexed_texture_sampler.sv` | Two unchanged instances | Existing Apache-2.0 baseline asset |

Baseline: `31a83135a22f845d85840524986895217567625c`. No old dependency is edited. There are no external runtime files, generated coefficients, firmware, vendor IP, network build steps or hidden includes. Sampler index/palette memory is populated at runtime through explicit load ports. Test vector files are generated once by the local reviewed oracle and archived before HDL; they are simulation inputs, not hardcoded hardware output images.

Semantic dedup examined the actual `fragment_rgb_depth_store`, `rgba_sprite_blit`, common-scaffold multiframe image adapters, and operator-library `osd_blend_u8` and `sprite_blend` sources/specs. Existing RGB stores assume opaque destination alpha; independent byte interpolation does not implement the premultiplied coefficient table or retain destination coverage. Repository searches for premultiplied/Porter-Duff/atop/destination-over found no implemented equivalent.

External technical reference (read-only HTTPS inspection; no downloaded code executed or introduced): official `https://github.com/google/skia`, commit `793b8ac73d4bf19a4812f04ab2b4479dc89a8da5`, `include/core/SkBlendMode.h`, `src/core/SkBlendMode.cpp`, and full root `LICENSE`. The latter is BSD-3-Clause, copyright 2011 Google Inc. The referenced coefficient semantics were independently specified in integer RGBA8 with explicit local rounding. No upstream code was copied or line-translated, and no Skia build/library dependency is required. Exact inspected file SHA256 values are in `references.json`.

New local code uses the repository's Apache-2.0 license text in `LICENSE`; unchanged dependency headers retain their original license. Frozen raw inputs and exact checked archives are linked by the final delivery evidence. Git clean normalization for the old dependency is recorded separately from raw SHA256 if applicable; raw simulation evidence is never silently normalized.
