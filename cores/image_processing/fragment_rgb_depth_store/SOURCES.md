# Independent implementation and reuse

Inspected baseline: `bbb761eb39c475ed52c7c42414a724e3f1ba6cae`.
All new RTL, wrapper, TB and Python are original Apache-2.0 code. The existing
triangle rasterizer is reused byte-for-byte only by the example; it retains
its existing Apache-2.0 source/license and is included once in that source list.
No shared production source, registry or historical receipt is modified.

Before local RTL creation, read-only source review inspected TinyRenderer
`our_gl.cpp` at commit `97eb7a480e762285899a93c5d21e70a79e60782e` and its
actual `LICENSE.txt`. The actual license grants use/alteration/redistribution
with origin/alteration/notice conditions: Zlib, not an assumed MIT license.
The source uses a floating point depth buffer, shader discard and framebuffer
pixel writes. It illustrates a renderer's depth-before-color ownership stage;
no source or build script was copied, translated or executed.

Pinned primary source and license:

- <https://github.com/ssloy/tinyrenderer/blob/97eb7a480e762285899a93c5d21e70a79e60782e/our_gl.cpp>
- <https://github.com/ssloy/tinyrenderer/blob/97eb7a480e762285899a93c5d21e70a79e60782e/LICENSE.txt>

`references.json` records a repeat read-only fetch's URLs, SHA256 hashes,
response sizes and times. This independent design instead defines unsigned16
smaller-is-nearer depth, four compare modes, explicit masks, exact integer
straight-alpha, synchronous RAM and ready/valid transactions. It makes no
OpenGL API, TinyRenderer rasterization/float-depth, stencil or shader claim.
The local Apache 2.0 LICENSE is complete; no third-party code is imported.

Semantic dedup searched standalone image/graphics, common-scaffold image and
signal_video, DSP/ISP, extended library, operator_library and compositor.
Actual neighboring interfaces/arithmetic were read:

| Existing function | Boundary |
| --- | --- |
| B33 `triangle_rgb_raster` | Generates sparse Gouraud `(x,y,RGB)` fragments; explicitly leaves framebuffer, depth and alpha blending to a consumer. Reused as an unchanged producer. |
| `cip_image_framebuffer` | Linear raster external-memory write/replay/read modes, aligned 32-bit words and one outstanding memory request; no coordinate-fragment RMW or Z plane. |
| `image/geometry` frame sampler/remap | Affine/projective inverse-coordinate sampling and image transforms; no depth arbitration or fragment destination ownership. |
| `dual_osd_stream`, compositor route/raster | Already-paired raster RGB overlay blend, scheduling and output timing. No generic coordinate-addressed persistent RGB/Z target. |
| Operator `sprite_blend`, `osd_blend_u8` | Per-beat supplied destination/source blending, no framebuffer RAM, depth or read/modify/write hazards. |
| `raytrace_cube` | Specialized cube intersection/lighting renderer with its own screen equations, not a reusable input-fragment store. |
| Image alpha/multiframe/filter assets | Ordered source frames and paired samples, distinct from sparse ordered drawing operations and persistent per-pixel depth. |

Search hits for texture statistics, network fragments, depthwise CNN and error
diffusion stencils were rejected as unrelated. No existing texture sampler,
blitter or generic fragment RGB/depth store matching this contract was found.
This package adds the destination stage rather than another image transform,
geometry rasterizer, renamed alpha operator or new tone formula.

Production closure: `rtl/fragment_rgb_depth_store.sv`. Example closure: that
file, `example/triangle_depth64.sv` and the existing sibling triangle RTL.
There are no ROMs, generators, runtime data or external-memory dependencies.
Frozen validation vectors, original executable inputs, raw tool streams and
hashes are retained. Simulator binaries are ignored temporary files for parent
cleanup and are not required source assets.
