# Frozen status

Completed: synthesizable bidirectional D65/sRGB CIELAB8 stream conversion,
ROM generation and assets, independent integer and direct CIE formula models,
actual OpenCV comparisons, protocol/recovery tests, and complete isolated mapping.
All changes are confined to this new directory; no shared files or JTAG touched.

Commands run successfully from the repository root:

```powershell
python -B cores/system/common_scaffold/image/cielab_color/run_tests.py
python -B cores/system/common_scaffold/image/cielab_color/synth_cielab.py
```

Final simulation: 3248 byte-exact pixels, 22.531 seconds; OpenCV 5.0.0 maximum
differences forward [1,2,1] / inverse [1,1,1], direct floating CIE maximum 1.
Protocol: 10 multiline frames / 60 pixels; 9 CE=0 reset phases with 9 healthy
recovery frames; 4 invalid static geometries. All PASS.

RGB8→Lab8→RGB8 roundtrip max [16,2,4], direct formula same [16,2,4], actual OpenCV
[16,4,4]. Worst measured input [4,188,245] returns [20,188,245] in this core,
the direct formula and OpenCV. This is byte-Lab quantization, not an exact
roundtrip guarantee; it must be included in downstream acceptance expectations.

Complete isolated `synth_gowin` and `check -assert` pass 16×16 / 31×33 / 65536×1:
LUT1..4 1844/1848/1852, ALU1336, FF786, SPX9×8, DSP0. No route/timing or
board verification claim. Synthesis includes both ROMs, not a black box.

TemporaryDirectory removed generated testbenches, executables and working files;
only small source/ROM assets and JSON evidence remain. Frozen source/asset
SHA256 values are recorded in `freeze_hashes.json`.
