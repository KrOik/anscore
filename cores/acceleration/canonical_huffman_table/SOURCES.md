# Provenance and capability review

Original ANSCORE RTL, wrapper and tests, Apache-2.0; full license is at `../../../LICENSE`. No external RTL, generator, source excerpt, coefficient table or binary is incorporated.

Read-only external review on2026-11-06 (Asia/Shanghai), before implementation:

- [RFC1951, section3.2.2](https://www.rfc-editor.org/rfc/rfc1951): canonical code assignment from code lengths. The RTL uses a serial length/symbol scan rather than the reference's histogram algorithm. Generic incomplete prefix codes are accepted; DEFLATE format validation is outside scope.
- [zlib1.3.1 inftrees.c](https://github.com/madler/zlib/blob/v1.3.1/inftrees.c): count-based oversubscription test and symbol sorting reviewed as algorithm background. [Versioned zlib license](https://github.com/madler/zlib/blob/v1.3.1/LICENSE) was inspected before implementation. No zlib code is copied. The local test oracle independently uses length counts/Kraft availability and first-code recurrence.

External search through the web tool failed HTTP500. The same primary documents were then read successfully using direct HTTPS requests; no external scripts were executed or retained.

Semantic duplicate review used repository-wide source/README search and read the existing PNG decoder source. `common_scaffold/dsp/jpeg_huffman` supplies fixed AnnexK codewords. JPEG headers carry fixed numeric tables. Existing PNG/JPEG decoders construct private decode tables coupled to their parser state; they do not expose runtime encoder queries or a staging/active atomic codebook service. The JPEG entropy bit packer accepts codes selected elsewhere. Reusing these whole parsers would introduce unrelated format and frame-storage dependencies. This package adds the missing generic dynamic encoder-side codebook service. It does not claim that canonical construction is a new algorithm.

No mature production source was modified. Source dependencies are only `rtl/canonical_huffman_table.sv` and, optionally, `example/huffman_byte_table.sv`.
