# Exact serial matrix products and registered sums

Previous candidate v5 retained real product registers but failed setup26.84MHz; actual critical was signed32xunsigned16 full multiplier into matrix_y0. This v6 replaces six matrix multipliers with16concurrent shift-add CSA iterations, followed by6byte carry-fold iterations.48-bit two-complement products are exact for every signed32-bit coefficient and unsigned16-bit coordinate. Existing matrix three-input CSA/byte register and COMMIT stages remain.

Affine input-to-valid becomes25enabled edges (baseline2), perspective264(baseline241); scale remains240. Ready/valid and CE freeze semantics remain explicit, no original golden modified. Original14-profile rotation reference PASS:5304commands,107240outputs,30resets. Seven UART normal/fault/watchdog cases PASS. Additional10000full-range random matrix records, all6products,60000signed product checks PASS. Temporary binaries/fixtures auto-cleaned.

OSS attempt rotate_serial_20261019 running. Production/shared RTL and JTAG untouched. No final hold timing qualification. Earlier failed v3,v4,v5 artifacts retained.
