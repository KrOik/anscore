# Provenance, licenses and distinction

The new detector RTL, full-port example, threshold-set/Fraction reference,
fixed cases, TB, validation, guards and documentation are original authoring.
They contain no translated or copied VLFeat implementation. Source identifiers
use Apache-2.0. LICENSE and NOTICE are exact copies of this repository's root
Apache-2.0 LICENSE and NOTICE, and apply to the package and reused dependency.

The unchanged production dependency is the exported B29 file
`cores/image_processing/grayscale_max_tree/rtl/grayscale_max_tree.sv`,10866 bytes,
SHA256 `39d42c70847386e1094fbc6faa3a346cb3af721ff75cbf4a4632769b6364d2e5`.
It bears SPDX Apache-2.0 and has no separate directory LICENSE. B29 release
is `d3eb85983cfa00dce57eccbe588aecfa581a9778`; manifest
`docs/snapshots/source_20261105_b29.json` SHA256
`260620629b9b73fb890dd379114f47556d7d788b494487e9d959a8abbb42b9f2`
records this exact source. Neither that file nor any old max-tree tests,
oracles, evidence or package docs are changed or rerun. No divider dependency
or protected untracked file enters the production closure.

Read-only algorithm research inspected VLFeat commit
`1b9075fc42fe54b42f0e937f8b9a230d8e2c7701`:

- [vl/mser.c](https://github.com/vlfeat/vlfeat/blob/1b9075fc42fe54b42f0e937f8b9a230d8e2c7701/vl/mser.c),30291 bytes,
  SHA256 `2f0ec3813d4d119bfdaa4b5f6749f97ee04af0fc9957ef0325d9cd12817a5064`.
- [COPYING](https://github.com/vlfeat/vlfeat/blob/1b9075fc42fe54b42f0e937f8b9a230d8e2c7701/COPYING),1365 bytes,
  BSD-2-Clause, SHA256
  `33b9f7703327199088d74f884b19997a0084180f984724720095a7cb412c4d89`.
- [Official MSER overview](https://www.vlfeat.org/overview/mser.html), inspected
  content SHA256 `77e2c8287895cd3e2ee1f5ee5ce136f9bdc81b4b69dbf5c53de931f8f8f175be`.

VLFeat documents a one-sided variation that differs from the original MSER
paper's symmetric criterion. This package explicitly fixes its own single-sided
area ratio, root exclusion, adjacent-gray pair selection with parent tie,
strict rational threshold and disabled diversity. No general VLFeat/MSER API
compatibility, ellipse/mask equivalence or all-options reproduction is claimed.

The new selected-region flags and exact variation/filter phases add a distinct
functional stage over the existing dense max-tree core; exposing the old tree
alone would not implement this contract. The reference constructs all connected
sets per present threshold and uses containment/Fraction, independently of the
production dependency's sorted activation/union-find and new serial walk FSM.
The original process_tree.py was previous original worker launcher code from
grayscale_graph_segmentation, original SHA256
`d43f929de708d66fcf8218c902b4d7c8bc61c6bb2984ee6a1f6d8ca1bd45d011`;
reuse covers source only, with no inherited test or runtime claim.


Repair01 runtime provenance: TOOL_INVENTORY.json is an exact local byte copy
of cores/signal_processing/exact_1d_transport/TOOL_INVENTORY.json at SHA256
9731eaf4054dc619c878347f39bb3e8f2e02d6f739c46ae0c07feccd9373060b.
runtime.py copies its sim/runtime.py at SHA256
7419e696ad10d1f4e8daca7e4fed45f5e4517e7db7a8f27f88441913de65f3f2.
These Apache-2.0 sources are self-contained in this package; future guards
do not depend on the mutable B package. The inventory was independently
rehashed from actual file bytes using external stdlib inspection; no runtime
guard or tool was invoked during C authoring. The process helper derives from
the original hash stated above and now adds explicit containment and process
context metadata. Its mechanics are unchanged; its new raw hash is sealed.
