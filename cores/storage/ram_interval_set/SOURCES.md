# Source/license preflight and semantic deduplication

Baseline: B24 release `d35d71be3bfc76f272809ae250d19cba92dbb18c`.
Before any new package file, an independent read-only capture matched the
published baseline's48 protected stable/snapshot references (raw object/type/
peeled commit), original15 tracked dirty paths/binary diff, goal.txt raw hash,
the full21000 original nonignored untracked path count and both NUL/LF hashes,
branch and empty index. No protected/user path was modified by this package.

## Existing contracts actually inspected

The storage package inventory and real contracts were read, with focused
operations/publication/reset sections and the relevant system RTL:

| Existing capability | Stored identity/order and resulting operation |
|---|---|
| range_lock_manager | independent owner/generation holders, shared/exclusive conflict and exact release/replace; adjacent holders retain their identities |
| extent_pool_allocator / buddy_pool_allocator | owned allocations, aligned allocation policy and exact whole-allocation release |
| ram_sg_range_map | original ordered segments/ordinals; logical concatenation translated to physical fragments |
| ram_region_guard | explicit policy slots and the lowest intersecting slot's whole-span permission decision |
| ram_byte_write_coalescer | one frame's final byte values, sparse external writes and acknowledged per-beat failures |
| ram_read_gather | frame-local exact address duplicates, external reads and replay in original item order |
| weighted_interval_schedule | maximum-weight nonoverlapping subset of original signed intervals |
| utility prod_range_guard32 | actual RTL compares one scalar to lower/upper bounds using a CE-qualified interface |
| DMA SG / 2D burst planner | descriptor payload movement or row/burst address planning |

The broader source/module/README scan found no persistent canonical interval
union/difference service. This package retains the exact byte set, combines
touching components, subtracts arbitrary portions, measures coverage and
enumerates maximal components. Capacity-atomic subtraction can fail when a
split increases component count, even though no new byte is added. That state
transition is useful for range maintenance and independent of a parameter,
opcode constant or bus-width change to an existing core.

## Fixed upstream source, read completely before RTL

The reference is [jeffparsons/rangemap](https://github.com/jeffparsons/rangemap)
at immutable commit
`fbd1575a862983b6eb4eacbde082ab4f5b57a7bb` (Cargo version1.8.0).
All eight files below were fetched as raw bytes, hashed and read in full
before any RTL, including full test text where present. No Rust/source/test
was executed, copied, adapted or persisted in this package.

| Fixed raw path | Bytes | SHA256 |
|---|---:|---|
| [src/set.rs](https://raw.githubusercontent.com/jeffparsons/rangemap/fbd1575a862983b6eb4eacbde082ab4f5b57a7bb/src/set.rs) |22778|210413b4b4722b47894dede2ccc29503a548858539845ad65328ef464d6649b5|
| [src/map.rs](https://raw.githubusercontent.com/jeffparsons/rangemap/fbd1575a862983b6eb4eacbde082ab4f5b57a7bb/src/map.rs) |61880|0ad868bba6723c7bb485b564f5add4ebb8d42abda9e6bfb4b5059e70cdb79f2d|
| [src/operations.rs](https://raw.githubusercontent.com/jeffparsons/rangemap/fbd1575a862983b6eb4eacbde082ab4f5b57a7bb/src/operations.rs) |6386|3de117027ebee26ff1150602a0245a7ee71e4fee72dfd8b190dda417fcb7b811|
| [src/range_wrapper.rs](https://raw.githubusercontent.com/jeffparsons/rangemap/fbd1575a862983b6eb4eacbde082ab4f5b57a7bb/src/range_wrapper.rs) |6408|224061af79ed9b5660cc1103c84d01ba15590eef2209ef1d49c7a1148e21112d|
| [src/std_ext.rs](https://raw.githubusercontent.com/jeffparsons/rangemap/fbd1575a862983b6eb4eacbde082ab4f5b57a7bb/src/std_ext.rs) |12579|897fd44669934057df2078c9c3354b9a3fbcbdfb517f009a98399a1d25ce89a9|
| [Cargo.toml](https://raw.githubusercontent.com/jeffparsons/rangemap/fbd1575a862983b6eb4eacbde082ab4f5b57a7bb/Cargo.toml) |2459|43c28e9b5ea840c9a83d1c2b1345d7094918e396ec465a4f3f4512dfdefa1b2a|
| [LICENSE-MIT](https://raw.githubusercontent.com/jeffparsons/rangemap/fbd1575a862983b6eb4eacbde082ab4f5b57a7bb/LICENSE-MIT) |1055|29a4c3823ee29ee5a97c145574a1bac20629fd5e6708be1df0d25bab563e093c|
| [LICENSE-APACHE](https://raw.githubusercontent.com/jeffparsons/rangemap/fbd1575a862983b6eb4eacbde082ab4f5b57a7bb/LICENSE-APACHE) |10837|1c7745cc26c7294bc9dbc883bcd50700b99a8c0f4859bfce84ec555098ce1ab5|

Cargo declares MIT/Apache-2.0 alternatives; both complete licenses were read.
RangeSet delegates to RangeMap<T,()> backed by dynamically allocated BTreeMap.
Insert adopts every equal-valued overlapping/touching range, using strict
overlap and non-strict touches. Remove deletes an overlap and preserves zero,
one or two edge fragments. The separate half-open Union iterator only merges
overlap; canonical adjacency is established by RangeSet insertion/touches.
The range wrappers provide start/end tree searches under ordered-disjoint
invariants. These are software mechanisms without finite component rejection,
private RAM publication, ordinary ready/valid ownership or reset cancellation.

The local serial packed RAM/FSM, atom oracle, bitmap crosscheck, finite fixtures,
TB, wrapper and runner are original Apache-2.0 work. The local [LICENSE](LICENSE)
is the repository's complete Apache-2.0 text normalized to LF. The production
closure is one local RTL file plus the optional local wrapper. No external
source, library, initialization image, generated ROM or runtime network is
required. Pure network/source reads are provenance, not tool/HDL qualification.
