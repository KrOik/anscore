# C18 semantic, fixed source and full-license preflight

Baseline `eb16eee7848694a1a1cd50e567b5742352751c93`,2026-11-05. Actual
tracked and untracked production searches (including `rg --no-ignore` under
cores, scoped to RTL/README/SPEC) for enclosing/minimum/bounding/smallest circle,
Chinese equivalents, convex polygon intersection and separating-axis terms
found no circle-bound service. Actual Hough circle, spatial-moment and segment
clip contracts were read, together with the previously inspected point-hull
and shape-distance contracts. Hough votes ring pixels, moments accumulate
weighted centroid statistics, and hull/clip/raster/RDP/Fréchet/Hausdorff perform
different objectives. No older source is changed, copied into or required by
this new independent primitive.

## Actual upstream implementation and complete license before local RTL

GitHub's commits API resolved the upstream master reference to immutable commit
`9991ad3d402b98b8e377af1a2789b4a4b000ccfa`. Before any local RTL, the complete
following files were fetched read-only with15-second HTTPS limits and strict
UTF8 decoded/read. The long GPL display's truncated middle was explicitly
reread from byte15000 through27000, completing full text inspection.

| Fixed file in nayuki/Nayuki-web-published-code | Bytes | SHA256 |
| --- | ---: | --- |
| [smallest-enclosing-circle/smallestenclosingcircle.py](https://github.com/nayuki/Nayuki-web-published-code/blob/9991ad3d402b98b8e377af1a2789b4a4b000ccfa/smallest-enclosing-circle/smallestenclosingcircle.py) |5217| `84d88b9372b104f52578223ffc308b457271af879d5560a17e61c05e00e06dc3` |
| [smallest-enclosing-circle/COPYING.txt](https://github.com/nayuki/Nayuki-web-published-code/blob/9991ad3d402b98b8e377af1a2789b4a4b000ccfa/smallest-enclosing-circle/COPYING.txt) |35147| `8ceb4b9ee5adedde47b31e975c1d90c73ad27b6b165a1dcd80c7c545eb65b903` |
| [smallest-enclosing-circle/COPYING.LESSER.txt](https://github.com/nayuki/Nayuki-web-published-code/blob/9991ad3d402b98b8e377af1a2789b4a4b000ccfa/smallest-enclosing-circle/COPYING.LESSER.txt) |7651| `da7eabb7bafdf7d3ae5e9f223aa5bdc1eece45ac569dc21b3b037520b4464768` |

The source names Project Nayuki2025 and LGPL3-or-later, not MIT. The complete
GPL3 base terms and LGPL3 additional permissions were actually inspected,
including source/modification/combined-work conditions, relinking/source
requirements, installation information, termination and warranty/liability.
These are provenance-only references: no upstream code, comments, tests,
license text or build files were copied, translated, adapted, imported,
persisted or executed. No upstream package or derived library is redistributed.

The viewed implementation shuffles floating-point points, iteratively repairs
one/two-boundary circles, chooses left/right candidate circles and uses hypot
plus relative epsilon. The independently designed local RTL enumerates bounded
support certificates with exact integer sign, angle and containment arithmetic,
and returns a deterministic unreduced rational encoding with no epsilon. Its
oracle uses original exact recursive boundary-set recursion and Gaussian
bisector solves; it imports no upstream module and contains no translated
incremental left/right repair implementation. No upstream API, floating behavior,
random tie or empty-result compatibility is claimed.

All local RTL/TB/oracle/docs are original Apache-2.0 repository work, under the
unchanged root LICENSE/NOTICE. Production closure is the one local RTL source;
the example adds only its own frontend. Python standard library and existing
repository Icarus/vvp are the complete optional verification tool dependencies.
No network, vendor primitive, external RAM, coefficient or generator is needed
for offline use. No inherited qualification is rerun or promoted.
