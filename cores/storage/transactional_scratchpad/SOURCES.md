# B16 semantic and source preflight

Baseline `83b11ea30d4762c5893cf37a8303b11706321876`. The complete 60-package
manifest `docs/snapshots/source_20261105_b15.json` was enumerated and each
README opening inspected. Targeted repository searches for transactional
memory, read/write sets, optimistic commits and commit conflicts found no
existing service. Broad shadow/abort matches in unrelated board/peripheral
assets were not treated as transaction implementations. Actual complete
`atomic_scratchpad` README/RTL and `sys_atomic_config.v` were read: the former
serializes one word's RMW; the latter switches a single shadow configuration
bank at an apply boundary. Neither retains several independent variable-address
read/write sets, repeatable reads, private writes, or dependency conflicts.
Block interning owns immutable content references; range locks exclude hazards
before work. This package adds optimistic multiword transaction lifetimes and
atomic commit/rejection over a shared committed word image.

Before local RTL, actual source from
[Marthog/rust-stm](https://github.com/Marthog/rust-stm/tree/91628b415ab401aa3d67f0c9e8a1f2e686ce1a6b),
fixed commit `91628b415ab401aa3d67f0c9e8a1f2e686ce1a6b`, was downloaded and
read in full, together with both complete license files and the package license
declaration. The search endpoint failed HTTP500; GitHub API repository discovery,
fixed-commit resolution/tree inspection and exact raw downloads succeeded.

| File | Bytes | SHA256 |
| --- | ---: | --- |
| `stm-core/src/transaction/mod.rs` | 15357 | `e4e73e8fdfe97d60763fb0709d3c617b49f5bfb6757ad98852b93f639f6fd8ff` |
| `stm-core/src/transaction/log_var.rs` | 3637 | `3a45de5c8e06d194bae971e1c0c07726dc4890f928cbf25f6059b5554ef855fe` |
| `stm-core/src/transaction/control_block.rs` | 3513 | `1f1433f47f2df5397985517a848920afc687c3665606d45a481ed85325534f41` |
| `stm-core/LICENSE-MIT` | 1072 | `14a26575e1299f83c7549de1459437ae9b0ca1b657c0575bf4f2ae96c014356a` |
| `stm-core/LICENSE-APACHE` | 11358 | `c6596eb7be8581c18be736c846fb9173b69eccf6ef94c5135893ec56bd92ba08` |
| `stm-core/Cargo.toml` | 1277 | `68c01e0801901a54b515934a31e0e2e6efb49da4473950d0b81a1bbdf21b59c2` |

The MIT notice identifies the 2015-2016 rust-stm Developers; Cargo declares
`MIT OR Apache-2.0`. Transaction read/write logs preserve original external
reads and return private writes. `commit` takes ordered locks, checks every
external read's object identity, and publishes all writes after validation.
Blind writes have no original-value dependency. Its software threads, locks,
dynamic BTreeMap/Arc objects, blocking retry and alternative calculations are
outside the local hardware contract. No fetched program/build/test ran.

The local RTL, tests and prose are original Apache-2.0 contributions. No
upstream code was copied, adapted or redistributed. Serial command ownership
replaces locking; bounded per-context RAM logs and explicit conflict invalidation
replace software object-identity validation. Same-value committed writes also
invalidate a recorded read. The independent Python oracle uses unbounded
per-address epochs, not the RTL's invalidation scan or conflict latches.
The complete local LICENSE and package manifests permit offline standalone use.
No external code, package manager, generator, initialization file or sibling
RTL is required.
