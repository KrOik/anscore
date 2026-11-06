# Capability and architecture decision

Semantic deduplication read the full-frame three-channel integer Lloyd K-means
and Lab quantizer descriptions, the binary-image Euclidean distance transform,
the resident INT4 matrix engine and low-precision inference package inventory.
Those provide training/assignment over unsigned triplets, per-pixel spatial
distance, dot products and neural layers. This core instead retains a caller's
pretrained high-dimensional signed8 codebook across independent queries,
validates explicitly published prefixes, returns exact nearest/runner-up
distances, and decodes the selected representation with original residuals.
It does not repeat RGB clustering with a different constant or bit width.

Alternatives were a full K-way distance array, dot-product reformulation
using cached codeword norms, and direct serial squared differences. The full
array replicates multipliers and reductions. The dot form can reuse norms but
needs additional norm publication and signed intermediate width management.
Direct difference/square avoids that consistency state and bounds every
intermediate simply. One registered signed9 subtraction, one 9x9 square and
one unsigned24 accumulator are reused for all K*D components. A strict
comparison while traversing rows in ascending order implements deterministic
ties. A separate FINISH state commits the final candidate before summary.

The codebook and cached query have synchronous reads; payload is never reset.
Each component takes four computation clocks: read pair, difference, square,
accumulate. Per-query prefix checks take K clocks; input takes D successful
transfers; replay takes two clocks per component without stalls. A conservative
command-to-final-replay service bound with continuously available input and
always-ready outputs is K + D + 4*K*D + 2*D + 8 clocks. Configuration and reset
are separate. Input gaps and output stalls add waiting, with no unconditional
completion deadline. This is an RTL schedule, not measured hardware throughput.

Default logical payload is 16*16*8=2,048 codebook bits plus16*8=128 query bits.
Maximum is64*256*8=131,072 codebook bits plus2,048 query bits. Prefix metadata is
9*MAX_CODES bits (144 default, 576 maximum), held in small registers and reset.
No per-component validity bitmap, unrolled distance bank, external memory,
vendor primitive or new CDC is introduced. Constant row-stride addressing may
need care for non-power-of-two MAX_DIMS. Resource risk is LOW at defaults and
MEDIUM at maximum capacity due to RAM packing, address decode and inference.
No LUT/DSP/BRAM count, frequency, power or device-fit result is claimed.

The example adds the inherited three-register RNE quantizer at IN_W9/OUT_W8;
the exact residual is available from the core when lossy residual coding is
unsuitable. Codebook precision, distance metric and application-level accuracy
are explicit design choices rather than inferred training guarantees.
