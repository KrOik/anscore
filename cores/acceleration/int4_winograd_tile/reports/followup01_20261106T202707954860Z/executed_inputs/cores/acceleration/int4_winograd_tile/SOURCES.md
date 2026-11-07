# Sources and provenance

This package's RTL, wrapper, model, tests and documentation are original
ANSCORE work, Apache-2.0. No upstream RTL, Python generator, SymPy output,
test or implementation code was copied, downloaded for execution or run.
Only the public mathematical transform identities informed the design.

1. Andrew Lavin and Scott Gray, *Fast Algorithms for Convolutional Neural
   Networks*, CVPR2016, official paper landing page:
   https://openaccess.thecvf.com/content_cvpr_2016/html/Lavin_Fast_Algorithms_for_CVPR_2016_paper.html
   Read-only HTTP200; no paper PDF copied into this package. Author copyright.
2. Author project https://github.com/andravin/wincnn, fixed commit
   `c2bf6305cc75866b19e204628b95baed4d13065c`.
   Specifically README.md:
   https://raw.githubusercontent.com/andravin/wincnn/c2bf6305cc75866b19e204628b95baed4d13065c/README.md
   Read-only HTTP200. Its F(2,3) and F(2x2,3x3) matrices define the variant
   recorded in ARCHITECTURE.md. Repository LICENSE is Apache-2.0, checked
   using the GitHub fixed-ref license endpoint before any formal submission:
   https://api.github.com/repos/andravin/wincnn/license?ref=c2bf6305cc75866b19e204628b95baed4d13065c
   The generator/SymPy are not dependencies of the delivered RTL or model.

The actual local example dependency is the unchanged production
`cores/acceleration/int4_weight_matvec/rtl/deps/stream_requantize.v`, the
already retained baseline alias of the production quantizer. Its 2423 bytes
have SHA256 `fdb7cb0fd3800694cd21f322c1cdfd7c8cba686d269fb7e0fe146a47cb0826a2`,
matching both the canonical production source and the int4_weight_matvec
entry in the B49 source snapshot. This original workspace dependency is
under the repository Apache-2.0 license. No source is copied or modified by
this package. Its prior evidence does not qualify this new composition.
Final closure records must bind its exact baseline blob before submission.

Semantic deduplication inspected production RTL/README/SPEC text for
Winograd plus the actual direct int4_conv3x3_frame and int4_weight_matvec
contracts. Existing direct convolution and other INT4 operators remain
unchanged. The new capability is transform-domain shared tile computation,
not another width/channel variant of the direct implementation.
