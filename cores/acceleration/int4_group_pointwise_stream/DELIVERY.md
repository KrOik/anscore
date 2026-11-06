# Grouped INT4 pointwise stream delivery

Adds resident grouped U8-by-S4 pointwise inference with per-row bias/scale/shift/output zero, exact RNE and S8 saturation. Optional channel shuffle changes output traversal without a permutation RAM. The actual two-RGB example boots fixed weights, centers six U8 channels and packs shuffled signed luma/opponent features.

Use files.f for the core or example/files.f for the real wrapper, resolved at this package root. The requantizer dependency is the unchanged committed int4_weight_matvec copy, not an uncommitted standalone path. See README.md and ARCHITECTURE.md for all handshake, shape, fixed-point and storage bounds; QUALIFICATION.json records the passed finite evidence.

One owner persists through completion retirement. Incorrect LAST ends the current frame; prior output prefix must be discarded. Reset cancels live work and the example reloads its resident configuration. Finite simulation does not establish device fit, timing or hardware performance.
