# Primary source and provenance

Laurent Condat, *Fast Projection onto the Simplex and the l1 Ball*, Mathematical
Programming 158, 575–585 (2016), DOI
[10.1007/s10107-015-0946-6](https://doi.org/10.1007/s10107-015-0946-6).
The final author version was read before this package was selected:
[author PDF](https://raw.githubusercontent.com/lcondat/lcondat.github.io/master/publis/Condat_simplexproj.pdf).
Observed file: 122229 bytes, 11 pages; SHA256
`fe59f109fbe19e306d7025010f4e7f332b693384e1015660b5cc2e0712edae5c`.

The simplex definition and threshold/KKT characterization support the exact
contract. Algorithm 4 (Michelot active-set method), its finite termination and
quadratic worst-case discussion informed the bounded RTL deletion scan. Algorithm
1's sorting/prefix characterization informed the independent Python reference.
The paper does not establish this implementation's register widths, port protocol,
RAM schedule or cycle count; those are derived in README/COST.

No publisher/author source code, image or PDF is copied into the package. The RTL,
Python tools, TB, wrapper and documentation are original implementations of the
mathematics. The paper is a citation, not an Apache relicensing of that paper.
Python's standard-library `Fraction` is used for certificate checks; no external
mathematical library or third-party HDL is required.

Existing interfaces were inspected read-only during selection: block_vector_normalize,
weighted_isotonic, nonnegative_least_squares2, stream_frame_sort and sequence_knn.
They establish capability boundaries and architectural comparisons, not direct
dependencies. No historical numeric checker or matrix was invoked.

Authoring validation is restricted to static source/JSON parsing, inspection and
hashing until root separately approves the exact preparation plan. No numerical
or HDL evidence is claimed at this stage. LICENSE is the repository's unchanged
Apache-2.0 license text copied into this new standalone package; NOTICE records
original contribution and external mathematical attribution.
