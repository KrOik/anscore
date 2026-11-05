# Scope and reference provenance

Baseline548ecff2b34281ec7b6f3306ba1c8d3af07f246d. New path only; existing
packages, protected dirty/untracked files, Git and shared documents are untouched.

The full current image package inventories and nearest actual production RTL
were read. Existing euclidean_distance already supplies exact squared distance
and lowest-raster nearest coordinates, and binary_hausdorff/chamfer_match reuse
it. Existing thinning, watershed and morph_reconstruction also cover those
candidate capabilities. CDF53 is1-D and Haar2D is a different transform, but
this package instead adds the absent GIF-LZW byte-to-index decode capability.
Repository README/RTL searches found no GIF or LZW decoder; gift-wrapping hull
mentions are unrelated. Existing JPEG/PNG/QOI/TIFF codecs use different coding
algorithms and are not dependencies here.

Read-only primary specification:
https://www.w3.org/Graphics/GIF/spec-gif89a.txt
The retained external reference is83003 bytes, SHA256
c0e48c12e3e91b1e78090caffb1d1ffe8e7d0face4350da675044a9a4be02aa3.
The deferred-CLEAR cover note, sections15/16/22, and Appendix F were read,
including arbitrary CLEAR placement, bit packing, width growth, EOI and the
sub-block terminator. The specification is referenced, not copied into this IP.

Read-only source comparison: https://github.com/mirrorer/giflib
Pinned commit fa37672085ce4b3d62c51627ab3c8cf2dda8009a, tree
9a0bb85a7dc90de8113f6b4928cfafd93ebd84b7. This is a reviewed mirror, not a claim
that its2019 snapshot is the latest release. Relevant full functions
DGifSetupDecompress, DGifDecompressLine, DGifGetPrefixChar,
DGifDecompressInput and DGifBufferedInput were inspected, together with the
complete private header and complete MIT license. No source was executed,
imported, translated line-for-line or used as a runtime dependency.

|File|Git blob|Bytes|SHA256|
|---|---|---:|---|
|lib/dgif_lib.c|66a1d6a4149f48c749dcfc9f46e52761e69cb412|41597|bd768d038d7078cc629dfce00133a9030e0daddf1e36f22428dda742bd103683|
|lib/gif_lib_private.h|adaf5571ea18c804da6fb2fd10a431373b388923|2464|b0353e12e5e136a97ae9b251fb72fe148cabf24822d833edb4efa8a19f48c0cd|
|COPYING|b9c0b50126076f30f0f9db7e940eac64e60febd6|1088|0c9b7990ecdca88b676db232c226548ac408b279f550d424d996f0d83591dd8e|

The complete original COPYING is retained as LICENSE.GIFLIB. Local authored
RTL, protocol model, word-dictionary oracle, fixed encoder, fixtures and finite
runner are independent. No upstream decoder is a golden executable. Two
hand-computed width-boundary certificates constrain the local encoder/oracle
and RTL separately. Full reference responses remain only in task-specific
.git/b27-c-* files. The web search service returned500; direct, fixed-reference
HTTPS reads succeeded without executing an external project.
