# Frozen local status

Implemented, simulated and isolated-synthesized. Board validation belongs to the
parent integration task and is not claimed here. All edits are confined to this
directory. No baseline or board artifacts were deleted.

Commands completed successfully:

```powershell
python -B cores/system/common_scaffold/image/hsv_color/test_hsv_color.py
python -B cores/system/common_scaffold/image/hsv_color/synth_hsv_color.py
```

Final simulation took approximately 6.8 seconds: 5308 exact integer-oracle
pixels with real OpenCV comparison, 11 protocol frames / 66 pixels, 6 reset
phases, 4 invalid static geometries. Held completion and error-code recovery
are included. Gowin isolated mapping and `check -assert` passed all 3 geometries,
at most 1035 LUT1..4, 682 ALU, 219 FF, 0 DSP, 0 RAM. This is not routed timing.

Temporary simulations and synthesis workspaces were automatically removed.
Retained evidence consists only of small source/reference/result JSON files.

Frozen SHA256:

- RTL: `EBF4375477B9CBAFBB6D71D9AC0A05432169110E3C761692D6E10C240DEB98DA`
- Main test: `897EB6AA4E5891E49C7D0E7FCAE210C897A72D9FC48F47287C82A91372020BA6`
- Protocol test: `46BC58B60A7CBFE024DFF01A5E574D37CE0D6114F20DBD36CBA778F28B8880D8`
- Synthesis script: `11D0AB04CF7F09FA064392337FB7D7BD75EE0F551CA7519C24B8B83E829C4D53`
