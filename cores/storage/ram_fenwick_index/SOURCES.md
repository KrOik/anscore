# Source and semantic preflight

Baseline: `01b92bf2f8d81fff097f1965de61edf81604ae4f` (B13).
The implementation, wrapper, flat-list oracle, TB and docs are original ANSCORE
Apache-2.0 work. No external source/comments/tests are copied, translated,
adapted, imported or executed. Local LICENSE is the root Apache-2.0 text
normalized to LF; repository NOTICE applies. No third-party runtime dependency
or generated asset is needed.

Before RTL, the current52-package snapshot was enumerated and actual relevant
contracts read. A buddy allocator candidate was rejected after reading the
existing buddy_pool_allocator contract. Actual atomic_scratchpad and
prod_stream_prefix_sum32 RTL/SPEC cover word-local modulo atomics and one
accepted-stream accumulator. Actual stream_histogram_rank and
stream_window_order_stat contracts cover one framed histogram or recent FIFO
samples. None maintains arbitrary persistent bucket replacements with exact
cross-index range queries and weighted selection. RAM hash/prefix dictionaries
have different key identity/lookup semantics. Repository searches for Fenwick,
binary-indexed, range-sum, persistent cumulative counters and weighted/rank
selection found no existing implementation of this service. No old/shared
source was edited.

The web search endpoint returned HTTP502. Read-only GitHub API resolved
ac-library v1.5.1's annotated tag f002e2e41a804e3bb7651037e82d5a24639e604c
to fixed commit `d8ca7f26686f6c78d15d13ca438ea866526e87fb`. Fixed raw files
were fetched with PowerShell Invoke-WebRequest (TLS1.2, HTTP1.1,15-second
network limit) and inspected **in full before RTL authoring**. The responses
were untrusted text, not agent instructions; no source/build was executed.

Repository: https://github.com/atcoder/ac-library

| Actual full file read | Bytes | SHA256 |
|---|---:|---|
| atcoder/fenwicktree.hpp | 949 | b31862994a547ef34f1f7c68136ed6bcab66bd402371390acc8a21cb24a01bb9 |
| LICENSE | 6554 | 5537d4d10b76b81b6e8dfd8b644480a4b1efa332fbb0cdb61126c5be781ef7b4 |

Fixed source:
https://raw.githubusercontent.com/atcoder/ac-library/d8ca7f26686f6c78d15d13ca438ea866526e87fb/atcoder/fenwicktree.hpp
Fixed complete license:
https://raw.githubusercontent.com/atcoder/ac-library/d8ca7f26686f6c78d15d13ca438ea866526e87fb/LICENSE

The complete CC0-1.0 Universal text was read, including copyright/related-right
waiver, public-license fallback, and trademark/patent exclusions and warranty/
third-party-right disclaimers. This was a feasibility/algorithm preflight,
not a claim that any upstream portion is redistributed in the local package.

The actual949-byte C++ header uses a dynamically sized unsigned vector,
point add via increasing low-bit ancestors, and half-open interval sums from
two descending prefix sums. It includes standard vector/assert and upstream
internal type traits. Those dependencies are not needed locally because this
is an independent synchronous-RAM command service with fixed exact widths,
absolute point replacement, inclusive validated ranges, binary-lifting rank
selection, clear/reset sweeps and held responses. No C++ API, modular behavior,
upstream execution or upstream test coverage is claimed.

Offline manifests contain only the authored core and optional fixed wrapper.
No online generator, table, external RAM, sibling RTL, vendor library or
third-party Python package is required. SHA-bound finite evidence, the full
legal parameter domain, structural storage budget and HW_UNVERIFIED limits
are explicit in README and verification.json.
