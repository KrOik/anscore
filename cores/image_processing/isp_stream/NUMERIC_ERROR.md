# Integer numerical error evidence

The reference is the specified integer pipeline, including rounding, clipping,
RAW-to-byte shifts and valid-window crop. Zero error means exact agreement with
that reference; it does not measure image quality against floating-point or
sensor ground truth. These are finite simulations, not physical measurements.

| Scope | Evidence | Checked pixels | Result |
|---|---|---:|---|
| Current AWB/CCM/Gamma chain | color_20261020T184159222421Z | 384173 RGB pixels | Exact bytes and metadata; isolated II=1 |
| Bayer normal/center modes | bayer_modes_20261020T182321831886Z | 380739 per RAW depth | Exact RGB/markers for RAW8/10/12 |
| All 64 integrated stage-mode combinations | all_modes_20261020T183333608166Z | 576 | Max/mean absolute byte error 0; marker/ID mismatches 0 |
| Sustained virtual-source full chain | realtime_20261020T183426663011Z | 829200 | Max/mean absolute byte error 0; marker/ID mismatches 0 |

The current color regression checks six frames, including 320x240 and 640x480,
with nonunity gains, signed CCM, bias, clipping and nonidentity Gamma tables.
It checks the composed color output, not a separate internal tap after each
arithmetic stage. Per-stage isolated evidence remains in VALIDATION.md.

`tools/report_numeric_error.py` independently rereads retained payload bytes,
checks the tested payload hash and current source provenance, reconstructs the
integer golden, and emits quantitative pixel and metadata errors. It reuses
the Python oracles from the original tests; it is not a second independent oracle.
It refuses an existing output directory and writes a FAIL report on rejection.

```powershell
python cores/image_processing/isp_stream/tools/report_numeric_error.py artifacts/isp_stream_25k/realtime_20261020T183426663011Z --kind realtime --output artifacts/isp_stream_25k/numeric_recheck_new
```

Reports do not establish board Fmax, physical continuous 30fps, hard-user-JTAG
control or real camera acceptance. Those gates remain open.
