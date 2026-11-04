# Source and architecture review — 2026-11-04

Development baseline: `cf23435`. This review preceded the new RTL.

## Semantic de-duplication

Production source/docs were searched for ECC RAM, ECC memory, SECDED memory,
scrub, memory repair and their Chinese equivalents.

- `stream_secded_encode` and `stream_secded_decode` operate on individual
  streaming codewords. They do not store addressed data, repair RAM, protect
  byte read/modify/write, or scan memory.
- `operator_library` has CE-qualified fixed-word ECC operators and
  `memprot_scrub_cursor_window`, which accounts for a caller-supplied bitmap
  and a rewrite budget. It never accesses or repairs payload RAM.
- Native BRAM, atomic scratchpad, memmove and the writeback cache do not
  provide ECC-protected storage or persistently repair corrected codewords.

This package adds an addressed, serialized memory service with read repair,
protected byte writes and whole-memory scrub with exact error counts. It
reuses the existing stream ECC modules without changing them.

## Fixed external read-only preflight

Repository: <https://github.com/lowRISC/opentitan>

Commit confirmed by GitHub API:
`0ea5236fe749e70ba18f56ba19c4be982ef46da7`.

Both files were retrieved with 15-second per-request limits and read before
implementation:

| File at that revision | Bytes | SHA256 |
|---|---:|---|
| `LICENSE` | 11,358 | `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30` |
| `hw/ip/prim/rtl/prim_ram_1p_adv.sv` | 14,304 | `061419332366621648121206740d274f1239b59c12a3fa4b9c78f5d233d1f379` |

The source identifies lowRISC contributors and Apache-2.0. Its memory/ECC
interface, width restrictions, full-word ECC write mask, optional pipeline,
and dependencies on primitive packages/macros/RAM/codec modules were inspected.
It has different reset, handshake and coding integration requirements. It
is a read-only architecture/interface reference; no source was copied,
translated, adapted, executed or made an offline dependency. No remote scripts
or build systems were run.

## Unmodified local dependency closure

- `../../acceleration/stream_secded_encode/rtl/stream_secded_encode.sv`
- `../../acceleration/stream_secded_decode/rtl/stream_secded_decode.sv`

Their actual ports and code layout were reviewed before the controller was
written. Both use standard ready/valid, synchronous-high reset and no CE.
They need no include/package/ROM/vendor files. The controller fixes their
DATA_W to 32 and internal TAG_W to 1, and ties off framing/tag metadata.
Production `files.f` lists both unchanged files before the controller.

The root LICENSE/NOTICE apply Apache-2.0 to original local contributions.
All new controller, example, tests, oracle and documentation are original
contributions. Prior physical or formal evidence of the codecs is not
inherited by this new composition.

## Qualitative architecture risk

**LOW** at default DEPTH=256: one 39-bit synchronous RAM array has 9,984
logical bits; one shared read and write address serializes all operations.
**MEDIUM** at maximum DEPTH=4096: 159,744 logical bits, uncertain device fit
and 39-bit BRAM packing, plus long initialization/scrub command occupancy.
There are no multipliers, vendor primitives, CDC or external memory
dependencies. Codec XOR/selection paths are pipelined by their existing
elastic stages. RAM clearing writes one word per clock rather than resetting
all payload bits.

The labels are structural judgments, not measured utilization/timing. Fault
injection is testbench-only; the hardware interface does not intentionally
corrupt RAM. SECDED guarantees cover zero, one or two flipped physical bits
per stored codeword; three or more can be miscorrected or missed. Memory
controller/codec faults themselves are not protected. All hardware remains
HW_UNVERIFIED.
