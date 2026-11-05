# Provenance and semantic dedup

Original ANSCORE ram_ordered_dictionary RTL, wrapper, oracle/program design and
runner adaptation,2026,Apache-2.0. No external software or HDL was copied.
LICENSE contains the Apache-2.0 text; NOTICE identifies this package.

Reused unchanged in-repository RTL:
cores/system/common_scaffold/memory/src/cip_sync_sp_ram.v
SHA256 04c0fe8416308c7e9a295d582dc7fee5fd8bbadf2fe4e745632543588c4f7619.
It is referenced directly, never copied or edited. Its byte-write/read-first,
one-response-slot/clk_en semantics are explicitly adapted with clk_en=1.
process_tree.py is an unchanged source copy of the previously reviewed internal
grayscale_graph_segmentation/process_tree.py,Apache-2.0
SHA256 d43f929de708d66fcf8218c902b4d7c8bc61c6bb2984ee6a1f6d8ca1bd45d011.
It is imported only after the future root approval and tested-copy freeze.

Semantic search covered the old108 B27 packages and maintained workspace
sources/docs. No persistent arbitrary-key ordered dictionary was found.
ram_hash_table provides exact hash operations, not scalar order/range traversal;
ram_prefix_table implements longest prefix, not scalar bounds;
ram_fenwick_index uses fixed bucket indexes, not sparse unordered keys;
ram_interval_set merges interval coverage, not independent key/value bindings;
ram_ternary_rule_table matches masked rules/slot priority;
ram_deadline_scheduler and binary_heap_queue expose minimum events, not a map's
arbitrary bounds/range updates; sorted_key_join consumes sorted frame streams;
LIS and stream_window_order_stat have frame/FIFO lifetimes.
B28 vector_banked_scratchpad is addressed vector RAM, not ordered sparse lookup.
This capability assessment is not a patent novelty claim.

Read-only primary algorithm/API reference (no code adaptation):
Boost.Container1.85 flat_map header,commit
6e697d796897b32b471b4f0740dcaa03d8ee57cc:
https://raw.githubusercontent.com/boostorg/container/6e697d796897b32b471b4f0740dcaa03d8ee57cc/include/boost/container/flat_map.hpp
SHA256 a44d45937db14ac9e09165013cc92bbe3c259d5e079a5a9b07c87030945b8b7a.
Only relevant representation/API/complexity sections were manually inspected;
the complete file was fetched/hash-verified, not claimed fully read.

https://www.boost.org/doc/libs/1_85_0/doc/html/container/non_standard_containers.html
SHA256 a3a2bde9d5d63d4048a2a1424d408d4ccbbcf915eb9afa01c3b6396ba4a9dc58.
A sorted sequence supports logarithmic lookup and linear shifting updates.
CPU locality/speed claims are not transferred to FPGA.

https://www.boost.org/LICENSE_1_0.txt
BSL1.0 SHA256 c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566.
License was read. No Boost code is incorporated; future code adoption would need
a full dependency/license/notice review before any incorporation.

The package is offline usable with its directly referenced in-repository RAM.
The qualified tool binaries are workspace infrastructure and are not vendored.
