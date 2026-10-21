# v106 guarded production integration

This driver does not program a board. The root agent owns all real hardware
operations and production README/manifest updates.

From the repository root:

```powershell
python -B cores/system/common_scaffold/image/filters/sim/production_temporal_v106_20261017/integrate_and_verify.py --preflight
python -B cores/system/common_scaffold/image/filters/sim/production_temporal_v106_20261017/integrate_and_verify.py --apply
python -B cores/system/common_scaffold/image/filters/sim/production_temporal_v106_20261017/integrate_and_verify.py --verify
```

Preflight tests a staged copy with the public module name, leaving production
unchanged. Its result is explicitly `PASS_STAGED_ONLY_NOT_APPLIED`.
Apply requires frozen sources, actual50MHz setup+hold, <=15K LUT/4DSP,
the original routed-netlist and bitstream hashes, and three distinct real
SRAM/JTAG0x1281b/exact57-byte UART records. Every record must contain frozen
source/netlist/fixture provenance and >=0.1s extra serial-byte observation with
zero extra bytes. Before the single RTL write, the driver retains original
RTL, README, manifest and their hashes under that run's `before/` directory.
The only production source transformation restores the module declaration
`img_filter_temporal_denoise_pipe` to `img_filter_temporal_denoise`.

Both production modes use the actual public production bytes for nine
functional configurations and five board-top simulations. Temporary bench
adaptations change only the DUT module identifier; numeric goldens, checker
and watchdogs are preserved. The unchanged original image_core group main
is reused with only its output-directory expression adapted; tool resolution
uses device_flow. In production mode the group compiles the actual production
temporal file. Preflight substitutes its proposed public-name copy.

All disposable VVP and temporary bench files live in a new local
TemporaryDirectory, removed even on failure. Small diagnostic logs, summaries
and executed commands are retained in append-only run directories. Existing
baseline files and failed evidence are not deleted or overwritten.

Hardware qualification is limited to the frozen GRAY8/MAX4x3 dual-DUT
self-test at50MHz/CE13of16. Functional MAX64x64 tests do not extend physical
timing qualification or claim continuous video throughput. The extra product
stage intentionally adds one enabled cycle per pixel relative to the old
LOAD/CALC/SEND schedule.
