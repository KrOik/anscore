# Offline closure and semantic dedup

Production `files.f` contains only `rtl/rgba_sprite_blit.sv`. It is a reusable
rectangle clip/flip/request/retirement controller with an explicit committed-write
idle input. There is no copied lookup, pixel RAM or alpha arithmetic.

The package-root-relative `example/files.f` contains the unchanged B37
`../indexed_texture_sampler/rtl/indexed_texture_sampler.sv`, the new controller,
unchanged B35 `../fragment_rgb_depth_store/rtl/fragment_rgb_depth_store.sv` and
new `example/indexed_sprite_frame.sv`. All use ordinary same-clock ready/valid
and synchronous active-high reset. No CE-qualified stream is directly connected.

Reviewed alternatives: `acc_sprite_blend` has fixed CGA16 and caller-supplied
indices/coverage, no resident image, rectangles or framebuffer; `acc_osd_blend_u8`
is a CE-qualified per-lane operator with no storage, destination geometry or
ownership; multiframe RGB blend uses Q8 unity256 and raster pairing, rather
than exact alpha255 coordinate RMW. B35 already implements the required RGB
source-over/frame memory and B37 the resident palette service, so both are
reused rather than reimplemented. The B37 triangle example has interpolated UV
and primitive ownership, but no exact texel rectangle, signed clip or flip command.

`reference_model.py` independently enumerates every destination viewport pixel
and tests membership of the original uncut rectangle; it does not reproduce
the RTL intersection endpoints/cursor recurrence. It indexes texture/palette
arrays directly and computes RGB channel results with integer weighted sums.
The core TB checks every UV/coordinate/tag request, visible fragment and DONE;
an independent delayed response queue plus commit delay exercises capacity,
backpressure and committed completion. The actual TB checks every RGB raster
word and the reused store's unchanged depth, frame counters and ownership.

The runner, model, plan, two TBs, two RTLs, two source lists and two unchanged
dependencies are11 archived inputs before numerical import/preparation. Every
vector is frozen before any HDL child. Raw streams, receipts and archives remain
immutable; successful VVPs stay ignored until orchestrator post-commit path/hash
cleanup. No external code, init image, network service or vendor primitive is
needed for offline use. Callers load the actual index/palette data at runtime.
