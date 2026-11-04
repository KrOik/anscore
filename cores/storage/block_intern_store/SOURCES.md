# B15 source and semantic preflight

Baseline: `9716da0847c26f09f4a9b856a84fc330dfb26351`. Before local RTL,
the 56-package catalog from `docs/snapshots/source_20261104_b14.json` was
enumerated and each package README opening inspected. A repository semantic
search for interning, block deduplication, content addressing, reference
counts and copy-on-write found no content-interning store. Point deduplication
in convex hull and reference descriptor/frequency counters do not own shared
payloads. Fresh complete README/RTL reads of `shared_packet_queues` and
`ram_hash_table`, plus buddy allocator/cache contracts, established the closest
boundaries. Packet queues own FIFO chains without content identity; hash tables
replace caller-chosen key/value bindings; buddy allocation owns geometric
addresses without payload; caches use address identity and mutable dirty data.
This package owns immutable complete content and shares one physical copy until
its final reference is released. It is a new storage capability, not a wrapper
or wider instance of those services.

The actual upstream implementation inspected read-only was
[droundy/internment](https://github.com/droundy/internment/tree/42f74c0109760cd476d6823b4d90887793b18634),
fixed commit `42f74c0109760cd476d6823b4d90887793b18634`.
On 2026-11-05, the commit was resolved through the GitHub API and the following
exact fixed raw files downloaded to a task-specific temporary directory and
read in full before local RTL. No fetched source, build, installer or test was
executed. The web search endpoint failed HTTP500; GitHub API/raw retrieval
succeeded. Initial master-source discovery was followed by fixed-commit reads.

| File | Bytes | SHA256 |
| --- | ---: | --- |
| `src/arc.rs` | 21002 | `d44c7727112d8b9eed6105d4fefc6b04768010024f1ce8224497a3a296dafc57` |
| `LICENSE-MIT` | 1056 | `3528317b4cafbde89260bc5f4cd823867d891f827e91c33ded6546044709f988` |
| `LICENSE-APACHE` | 10847 | `a60eea817514531668d7e00765731449fe14d059d3249e0bc93b36de45f759f2` |
| `Cargo.toml` | 3250 | `c3a02b74973fe26275869dd81bbeedfa6e73600e2624be8edd24d85b11de53d5` |

`ArcIntern::new` searches by complete value equality, returns an existing
pointer with incremented atomic count, or inserts a new allocation.
`Drop` removes the interned object after its final reference. `RefCount`
equality delegates to data equality; the implementation also uses hashing,
DashMap locks, allocation and concurrency races. The complete MIT and
Apache-2.0 license texts were inspected; Cargo declares `MIT OR Apache-2.0`.
This is behavioral reference material, not adopted production source.

The local RTL is original Apache-2.0 work. It replaces software allocation,
locks and hash-map probing with bounded physical slots, explicit ready/valid
commands, exact serial word comparisons, saturation rejection and serialized
synchronous RAM. No upstream code or third-party runtime dependency is copied
or included. The local LICENSE supplies the complete Apache-2.0 terms for
standalone redistribution. Offline manifests use only package files.
