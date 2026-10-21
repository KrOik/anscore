# Frozen implementation status

Changed files are confined to `image/raw_white_balance/`: synthesizable RTL,
exact oracle/regression runner, protocol/limits/reference tests, isolated
synthesis runner, reference fetcher, manifest, file list, documentation and
freeze/evidence JSON. No shared files or board scripts were edited.

Commands executed from repository root (all **PASS**):

```
python -B cores/system/common_scaffold/image/raw_white_balance/run_tests.py
python -B cores/system/common_scaffold/image/raw_white_balance/test_protocol.py
python -B cores/system/common_scaffold/image/raw_white_balance/test_numeric_limits.py
python -B cores/system/common_scaffold/image/raw_white_balance/test_reference.py
python -B cores/system/common_scaffold/image/raw_white_balance/synth_check.py
python -B cores/system/common_scaffold/image/raw_white_balance/fetch_references.py
python -B cores/system/common_scaffold/image/raw_white_balance/freeze.py
```

* Main: **160 cases, 13682 outputs** across seven width/height/RAW profiles.
  Automatic and manual, four CFA patterns, exact independent Fraction gains,
  pooled-green unequal populations, ROI/gating, gain limits, half-up/saturation,
  malformed markers, no samples, zero sums, thin images and recovery all passed.
* Protocol: **9 CE-disabled resets**, **10 recovery frames / 480 pixels**, one
  additional late marker fault, plus random CE/backpressure passed.
* Limits: seven illegal profiles rejected; conservative 64-bit bounds proved;
  one actual **256×256 RAW12 / 65536-output** hardware-gain frame passed.
* Mature reference: actual unmodified Infinite-ISP GrayWorld source executed;
  four pattern frames / 192 RTL outputs passed the shared equal-population
  numerical contract. Broader algorithm differences are explicit in README.
* Synthesis: 32×24 RAW12 **2652 LUT-class / 0 DSP**, 31×17 RAW10 **2660 / 0**,
  8×6 RAW8 **2680 / 0**. RAM16 charging and conservative BRAM9 units are in
  synthesis_result.json; all three measured isolated profiles meet the budget.

RTL SHA256: `51674e4655fa1c7c30c7b832caca587ba9c83ce30805532b8afbd6809c784e2e`.
All evidence records this exact hash. Builds, simulator images and downloads were
inside TemporaryDirectory and cleaned on exit. No JTAG/UART/board acceptance was
attempted. Shared registry integration and physical acceptance belong to root.
