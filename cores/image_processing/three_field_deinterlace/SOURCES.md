# Offline source closure

Core: `rtl/three_field_deinterlace.sv`, listed by package-root-relative `files.f`.
The core has no include files, ROMs, initialized memories, vendor primitives,
external controllers or shared RTL dependencies. Runtime capture supplies all
RAM values before replay; RAM contents do not need reset or initialization.

Complete composition: `example/deinterlace_rgb_preview.sv` instantiates the
unchanged core and turns its Y8 raster into RGB24. With first-pixel-latched
`cfg_tint_spatial=1`, spatial decisions produce `{255,Y,0}`; other decisions
produce `{Y,Y,Y}`. With tint disabled all pixels produce `{Y,Y,Y}`. Configuration,
capture, raster and DONE retain CE-qualified semantics at every boundary.
`example/files.f` contains both required sources. No adapter is required inside
this composition; an ordinary valid/ready external system needs a CE adapter.

Finite checks: `run_tests.py` (Python standard library only) and
`sim/tb_three_field.sv`; Icarus Verilog/vvp are external tools, not runtime RTL
dependencies. Exact executable source snapshots and generated numerical input /
golden vectors remain in each immutable `reports/<UTC>/` directory. Source
snapshots are created before numerical preparation; vectors are created and
hashed before launching any HDL tool. The runner records the exact ordered
plan, tool hashes, raw stdout/stderr hashes and completion markers. VVP files
are deliberately ignored under `.build/` and retained pending orchestrator
post-commit cleanup. Do not execute legacy helpers or external reference code.

All package implementation, model, TB and example code is original Apache-2.0.
`LICENSE` is the full Apache-2.0 license. FFmpeg YADIF source and its LGPL-2.1+
license were actually read as primary technical references; their URLs, fixed
commit and fetched UTF-8 content hashes are in `references.json`. No upstream
source was imported, translated, linked or executed. The independently fixed
three-field equations and their differences are documented in `README.md`.

Semantic review covered standalone image packages, common_scaffold/image,
signal_video, DSP/ISP, extended/operator libraries and compositor packages.
Existing HE/CLAHE already performs clip/redistribute/interpolate and was rejected
as a new task. Existing paired-field WEAVE/BOB/ADAPTIVE lacks same-parity
bracketing references and directional reconstruction. No mature source changes.
