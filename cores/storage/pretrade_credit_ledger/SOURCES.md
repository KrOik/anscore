# Sources and semantic boundaries

B38 baseline: `816d461b12fd402f6a146ca74c7491c7afbd3091`.
All new RTL, wrapper, model, testbench and runner code is original ANSCORE work
under Apache-2.0. Package `LICENSE` contains the full license. No external Java,
scripts, generated HDL or implementation fragments were copied or translated.

## Fixed external read-only reference

Repository: https://github.com/exchange-core/exchange-core

Pinned commit: `2f8548749839e9095c8dc597e4b61521d259fa5d`.

| File at that commit | Bytes | SHA256 |
| --- | ---: | --- |
| LICENSE.txt | 11355 | ffdbc6d3d15b227e50b3b85a712785067122b04d69ad92d78080278de2be2347 |
| src/main/java/exchange/core2/core/processors/RiskEngine.java | 36710 | 8e7f955e5079a013bd360bebc90fd354d2b2a0e71d34fc2391e1c6e5fe303c3a |

Read-only raw URLs:

- https://raw.githubusercontent.com/exchange-core/exchange-core/2f8548749839e9095c8dc597e4b61521d259fa5d/LICENSE.txt
- https://raw.githubusercontent.com/exchange-core/exchange-core/2f8548749839e9095c8dc597e4b61521d259fa5d/src/main/java/exchange/core2/core/processors/RiskEngine.java

The full license was checked as Apache License2.0. RiskEngine.java carries
Copyright2019 Maksim Zheravin and an Apache-2.0 header. The file was fetched as
untrusted data, hashed and inspected for pre-matching holds/rejections and
post-matching release behavior; it was never imported, executed or built.
Its account/fee/margin/settlement machinery is not implemented here. This package
is a distinct bounded unsigned hold service, not a port or behavioral equivalent
of exchange-core. No external source or license blob is a runtime dependency.

## Actual local semantic dedup

The following implementations/specifications were read, beyond name searches:

- `buddy_pool_allocator`: address-unit buddy metadata, allocate/release by
  order/base; no account ceiling or user ticket amount record.
- `extent_pool_allocator`: contiguous unit/address ownership, exact-length
  release; no independent credit denomination or global ticket hold.
- `range_lock_manager`: interval compatibility and generation/owner handles;
  no summed account credit limit.
- `atomic_scratchpad`: single-word read/modify/write, modulo fetch-add; no
  atomic ticket/account transaction service.
- `multiflow_token_shaper`: clock refill, capacity and descriptor-cost consumption;
  no matching keyed hold release or persistent ticket identity.
- `prod_stream_credit32`, `prod_token_bucket32`, `ctl_credit_arb8` SPEC: scalar
  deposit/withdraw or per-port grant credits; no full64 account-ticket lifecycle.
- `price_level_order_book` and `price_level_ioc_matcher`: aggregated L2 liquidity,
  checked quantity updates and IOC fills; no account risk/hold records. Actual
  matcher ports and the SUB-before-fill/final-after-fill boundaries were checked.
- `ram_hash_table`: full64 keys but max64 value; a complete ticket record would
  require another RAM and slot mapping. It was reviewed but is not a dependency.

Existing names alone were not used to infer a capability. This task adds the
coupled account sum, unique-ticket admission, saved-amount release and invalid
epoch semantics, rather than duplicating the existing allocators or shapers.

## Unchanged offline dependency closure

Paths are repository relative; all four sources are already committed.

| File | Use | SHA256 |
| --- | --- | --- |
| cores/system/common_scaffold/memory/src/cip_sync_sp_ram.v | Two core RAMs and existing book RAMs | 04c0fe8416308c7e9a295d582dc7fee5fd8bbadf2fe4e745632543588c4f7619 |
| cores/storage/ram_ordered_dictionary/rtl/ram_ordered_dictionary.sv | Actual example book dependency | 03b9bd7147fb0d0275df0f445aa7ee0895f2ee74d0cb38e57ba20ebce970aa91 |
| cores/storage/price_level_order_book/rtl/price_level_order_book.sv | Actual example matcher dependency | d69f03641c7928bf70fc28b44c59c4a892c62c3942d702deb11b4ac5d463d72e |
| cores/acceleration/price_level_ioc_matcher/rtl/price_level_ioc_matcher.sv | Actual example IOC implementation | 481440e8cfdc7650e6d193ce5f6bf36a91f6d91e385361504caa432c1f541c6c |

No dependency is edited or vendored. `files.f` closes the core and
`example/files.f` closes the actual composition from this package root. Shared
RAM has CE-qualified handshakes and synchronous read-first responses; each private
instance is tied enabled and explicitly issued/drained, preserving its protocol.
The example and reused IOC public ports are ordinary same-clock ready/valid.

The finite runner archives exact executed source/dependency bytes and the frozen
plan before oracle calls or HDL, retains raw logs, hashes vectors/tools/images,
and verifies current/archive equality. Final delivery maps current executable
sources to these archives. Temporary executables are not source assets and are
left for root's bounded post-submission cleanup.
