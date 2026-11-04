# Semantic/source/license preflight — 2026-11-04

Baseline: `f19addd5fec59ec6affee05af7195ca1758d40dc`. This review occurred
before writing new RTL.

## Semantic de-duplication and reuse decision

Production RTL and README/SPEC searches covered hash tables, persistent
key/value storage, linear probing, tombstones, cuckoo and Chinese equivalents.

- `operator_library/rtl/acc_tab_probe3_cuckoo.v` is an eight-slot, 16-bit-key,
  8-bit-tag CE-qualified register-state operator with three fixed candidates.
  It can reject a collision while other slots are empty; it has no deletion
  or RAM-based full-capacity probing. It cannot implement this service by a
  transfer wrapper or a width change.
- Stream run reduction, sorted joins and pattern matching do not retain a
  mutable dictionary across independent commands.
- Atomic scratchpad, writeback cache, ECC RAM, memmove and ordered completion
  have addressed/tagged payload semantics rather than exact persistent keys.

This package adds persistent GET/PUT/DELETE/CLEAR with collision resolution
through all slots, exact capacity failure, deletion chains and old-value
responses. All keys, including zero and all ones, are valid.

No applicable existing module supplies its key/value RAM and tombstone
lifetime. A private synchronous packed RAM and metadata array keep the
lookup/update atomic with respect to the sole command port. Instantiating
an unrelated FIFO/cache/CRC adds no needed capability. No old RTL is modified
or copied. There is no untracked or external runtime dependency.

## Fixed external read-only inspection

Repository: <https://github.com/alexforencich/verilog-ethernet>

Fixed commit, confirmed via GitHub API:
`77320a9471d19c7dd383914bc049e02d9f4f1ffb`.

| File | Bytes | SHA256 |
|---|---:|---|
| `COPYING` | 1,062 | `8ea57f95365e9b16a5b516f422b71269183a1ae53bab5878ae6d69039e58fe77` |
| `rtl/arp_cache.v` | 6,952 | `d8b573a7582c08f67f90aba9316d98e5b0e0c5bbcbcd7a6935d6537e3f4aa2f8` |

The complete MIT text and source were read before implementation. Both name
copyright 2014-2018 Alex Forencich. Initial raw/API attempts hit TLS EOF;
COPYING was then retrieved via the contents API, and the complete source via
a fixed raw URL. Each network request had a 15-second timeout.

The reference has separate query/write ports, 32-bit IP keys, 48-bit MAC
values, LFSR hashing and direct mapped replacement. Its `lfsr` dependency,
initial memory values and clear behavior were inspected. Collision eviction
is appropriate to that ARP cache but is not the dictionary contract here.
No implementation, LFSR module, scripts or upstream build process was copied,
translated, executed or included. The new hash is a documented XOR fold,
with serialized complete collision resolution and tombstones.

All new RTL, example, oracle, TB and prose are original Apache-2.0
contributions covered by the root LICENSE/NOTICE. No upstream source or
license-bearing implementation is redistributed.

## Structural risk

Default SLOTS=32, KEY_W=VALUE_W=32: 2,048 packed key/value bits plus 64
metadata bits, **LOW** qualitative resource risk. Maximum 256 slots, 64-bit
key/value: 32,768 payload bits plus 512 metadata bits, **MEDIUM** risk from
RAM mapping, indexed storage/control and comparator/hash width. Payloads
are read synchronously at one selected address and never reset in parallel;
clear writes one metadata word per clock. No multiplier, vendor primitive,
external memory or CDC is required.

Every lookup can visit all SLOTS, including a miss through tombstones.
Adversarial collisions and accumulated tombstones degrade latency, without
losing otherwise available capacity. No constant-time/security guarantee,
measured PPA, device fit or hardware validation is claimed. All versions
remain HW_UNVERIFIED.
