# Source provenance and reuse review

Original ANSCORE wrapper/datapath, example, runner and TB are Apache-2.0 under `../../../LICENSE`. No external source code or generated external artifact is incorporated.

Production dependency: unchanged `../canonical_huffman_table/rtl/canonical_huffman_table.sv`, originally delivered at Git commit `04ec10b2ef68add8deccfa54b3e3cc8cf11bed90`. The runner's `source_sha256` records its exact bytes. Its original Apache-2.0 license/provenance remains in the repository. The new wrapper does not modify or privately duplicate that module.

Read-only upstream review on2026-11-06 Asia/Shanghai, before authoring:

- [RFC1951 sections3.1.1 and3.2.2](https://www.rfc-editor.org/rfc/rfc1951): codeword significance versus byte-level bit order. This raw frame format explicitly uses MSB-first bytes and zero padding; it does not claim DEFLATE wire compatibility.
- [zlib1.3.1 trees.c](https://github.com/madler/zlib/blob/v1.3.1/trees.c) `send_bits`, `bi_windup` and byte emission were inspected with the [versioned zlib license](https://github.com/madler/zlib/blob/v1.3.1/LICENSE). No code is copied. Those little-endian bit reservoir details are deliberately not used by this serializer.

The web tool failed HTTP500; direct primary-source HTTPS reads succeeded. No upstream installer/build script executed and no downloaded upstream files remain.

Semantic search covered production RTL/README files for Huffman encoder/bitstream/canonical interfaces. B31 supplies dynamic lengths-to-code lookup, with bit packing explicitly outside its interface. Existing `common_scaffold/dsp/jpeg_bitstream/jpeg_entropy_bitpacker.sv` packs already-selected code/amplitude tokens with JPEG one-padding and0xff stuffing, and uses a CE-qualified interface; JPEG scan/frame encoders also impose JPEG syntax. Existing PNG/JPEG decoders own private decode tables. None offers this generic atomic symbol-frame-to-byte service. The distinct increment is an integrated actual symbol encoder with frame validation, no-partial-output error handling, explicit byte framing and bit counts. Codebook reuse is source/functional reuse, not a new physical-resource measurement.
