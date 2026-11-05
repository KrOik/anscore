# Provenance and semantic review

New wrapper, TB, runner/model and example are independently authored Apache-2.0
ANSCORE code. No external code was copied or executed. The package includes
the repository license. Reused production dependencies remain at their original
paths and are not modified or duplicated in production lists:

- `../ram_ordered_dictionary/rtl/ram_ordered_dictionary.sv`.
- `../../system/common_scaffold/memory/src/cip_sync_sp_ram.v`.

The actual checked receipt records their exact SHA-256 hashes. Historical
dictionary READMEs and seals describe prior stages; this package's finite
integration tests cover the reused RTL as instantiated here and do not upgrade
any historical hardware validation.

Before implementation, full repository RTL/README/SPEC/catalog content was
searched for market data, order books, bid/ask and price-level operations.
`docs/IP_DEVELOPMENT_FOCUS.md` supplies the new market-data priority. No existing
book implementation was found. Nearby capabilities were inspected directly:

- `ram_ordered_dictionary`: unique keys with replacement/delete/seeking/range;
  reused twice, rather than reimplementing ordered storage.
- `ram_range_min_index`: dense bucket assignment/interval argmin; does not
  retain arbitrary sparse runtime price levels or perform quantity aggregation.
- Heaps/deadline queues choose a priority item but do not maintain two-sided
  price-level quantities with checked aggregation, deletion and ranked depth.

The new capability is atomic price-level quantity service, bid/ask ordering,
per-side capacity and overflow/underflow/error behavior over shared backends.
It is not a renamed dictionary, matching engine or width variant.

Read-only external primary/open-source inspection used:

- Repository: https://github.com/nkaz001/hftbacktest
- Pinned commit: `5f3ec40b2afb764e0fea112f941ed85523ef4e88`.
- File: `hftbacktest/src/depth/hashmapmarketdepth.rs`, inspected for L2 side
  quantities, best bid/ask and the distinction from L3 order IDs.
- License: the pinned root `LICENSE`, MIT, copyright2022 nkaz001@protonmail.com,
  inspected before local authoring. The local integer tick/lot service does
  not reproduce that project's floating-point/timestamp/feed-refresh behavior.

Pinned raw source SHA-256:
`72de43ed8f67a2864f1b690f333ceed9ed16f73e3c7ea7be94d3642af0286307`
(31,213bytes). Pinned license SHA-256:
`b40367c13dfa67c617d6e8037d45581496d9f0429a3274ab19f117404b519a5a`
(1079bytes). Direct GitHub API/raw HTTPS reads resolved and inspected these
files. No installer, build, upstream script or other remote instruction ran.
