# Source and license record

Local production RTL, example, testbench, preparation and runner are independent
ANSCORE work under Apache-2.0. No third-party source was copied, imported or
executed. All upstream files were read only as algorithm/interface references;
comments and external instructions were treated as untrusted data.

Before implementation, complete files and complete CC0 license were read from
https://github.com/atcoder/ac-library at fixed commit
`864245a00b00dd008d1abfdc239618fdb7d139da`:

| File | Bytes | SHA256 |
|---|---:|---|
|atcoder/mincostflow.hpp|7380|88396cd7cae7274db2a1f9a0ffdfe8673ac508f7b3e6972a96d5b75e4b6bfe88|
|atcoder/internal_csr.hpp|751|1e55f89eb899552a60ae5c7603b2fb4adbaf8ac2217e8069eec834c5938454be|
|atcoder/internal_queue.hpp|668|028a31d5f4070d7b5b7d43b00e124bcd59cf3ca0674d0f12cd6b52c1604fd713|
|LICENSE|6554|5537d4d10b76b81b6e8dfd8b644480a4b1efa332fbb0cdb61126c5be781ef7b4|

AtCoder uses potentials/dual distances and a queue/heap-oriented software
organization. The independent FPGA architecture uses bounded serial
Bellman-Ford, synchronous packed original-edge/node/path banks, explicit
read/use/write states, full32-bit validation, sticky atomic stream errors and
backpressure. No AtCoder build process, C++ dependency or derived source is
needed offline. Full upstream reading preceded the frozen plan and RTL.

Actual existing maxflow_mincut, min_cost_assignment and signed_sssp contracts
were read for semantic deduplication; no shared source was modified. A discarded
read-only TSP idea produced no asset. A KACTL tree query timed out before any
source was adopted. Neither constitutes a production dependency.
