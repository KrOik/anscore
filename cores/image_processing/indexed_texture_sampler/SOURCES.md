# Offline source and interface closure

Production: `rtl/indexed_texture_sampler.sv`, package-root `files.f`. No include,
ROM/init image, external controller or vendor primitive is required. Load ports
supply all indices/palette entries before resident publication permits reads.

Actual composition, listed in package-root `example/files.f`:

- Unchanged `../triangle_rgb_raster/rtl/triangle_rgb_raster.sv` (B33).
- New `rtl/indexed_texture_sampler.sv`.
- Unchanged `../fragment_rgb_depth_store/rtl/fragment_rgb_depth_store.sv` (B35).
- New `example/indexed_triangle_frame.sv`.

All four modules use ordinary same-clock valid/ready and synchronous active-high
reset. The raster's exact RGB interpolation is reused as U8/V8/zero affine
attributes. Its sparse fragments feed the sampler; visible sampler results feed
the coordinate RGB/Z store. Invisible results retire without store transfers.
No source copy, renamed rasterizer, CE conversion or change to mature RTL is
introduced. The sampler's administration is gated for the whole primitive;
in-flight sample retirement and the store's own END readiness prevent early
completion/publication. Primitive Z/depth/mask values remain owned until DONE.

Finite checks: `run_tests.py`, `reference_model.py`, `PRECHECK_PLAN.json`,
`sim/tb_indexed_texture.sv`, `sim/tb_indexed_frame.sv` and both source lists.
Python standard library only. The core oracle directly indexes whole arrays;
the scene oracle enumerates every viewport center using direct determinants
and exact Python Fractions, then updates an ordinary RGB/Z coordinate dictionary.
It does not execute external sources or replicate a hardware RAM/FSM schedule.

The runner archives all11 actual inputs, including the two original dependency
paths and exact precheck plan, before importing/invoking the numerical model.
All vectors are archived/hashed before the first HDL child. Any existing started
report directory (including empty) prevents automatic retry; an INCOMPLETE
receipt is persisted before oracle import, around preparation and after every
child. Reviewed source/tool hashes and exact argv/cwd/marker templates are
enforced. Any child failure stops later launches. Raw streams,
completion markers, input/tool hashes and source copies remain immutable under
`reports/<UTC>/`. Successful VVP images remain ignored in `.build/` pending
orchestrator path/hash-verified post-commit cleanup. No legacy runner is invoked.

Original Apache-2.0 implementation/model/tests/example; full `LICENSE` included.
Project F's pinned actual sprite/CLUT/MIT license were read as technical sources
only; `references.json` records fetched UTF-8 content hashes. No upstream source,
ROM, script, build flow or bitstream is imported/translated/executed.
