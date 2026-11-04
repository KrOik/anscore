# Sources and offline closure

Independent original RTL, testbench and standard-library Python oracle;
SPDX Apache-2.0. No upstream source is copied, adapted or executed.

Before RTL, the complete relevant source and complete license were read only
from [AtCoder ac-library](https://github.com/atcoder/ac-library), fixed commit
`864245a00b00dd008d1abfdc239618fdb7d139da`:

| Exact file | Raw bytes | SHA256 |
|---|---:|---|
| [atcoder/string.hpp](https://github.com/atcoder/ac-library/blob/864245a00b00dd008d1abfdc239618fdb7d139da/atcoder/string.hpp) |7661|`e7ffe101a268208d63c17374e970f781a1a828feb6cc6010ead78c2a709cda86`|
| [LICENSE](https://github.com/atcoder/ac-library/blob/864245a00b00dd008d1abfdc239618fdb7d139da/LICENSE) |6554|`5537d4d10b76b81b6e8dfd8b644480a4b1efa332fbb0cdb61126c5be781ef7b4`|

The full CC0 1.0 text and full header, including naive, doubling and SA-IS
suffix construction, wrappers, LCP and Z algorithm, were inspected. The header
uses standard C++ includes. This package independently uses bounded serial
RAM insertion, unsigned runtime symbols, explicit capture/error draining,
reset ownership and atomic cached publication. It does not import or execute
the header or require any upstream dependency.

Whole-cores/docs suffix-array, suffix-sort, LCP and Chinese capability searches
found no matching asset. Actual contracts of `stream_frame_sort`,
`ram_prefix_table` and `stream_pattern_match` were read. They respectively
sort fixed records, route MSB prefixes and match fixed/wildcard patterns;
none constructs a runtime suffix permutation and adjacent common-prefix index.

`files.f` is the complete production dependency closure. Add
`example/suffix32.sv` for the default instance. There is no include, generated
ROM, sibling RTL, vendor primitive, external memory or network dependency.
All eight deterministic fixtures and the generator remain local for offline
reproducibility. The finite runner uses only Python's standard library and
the repository-local Icarus suite.
