# Source and license preflight

Original ANSCORE RTL, testbench, oracle, runner and integration example are
Apache-2.0, under the included repository license. No third-party source is
copied into or executed by the production dependency closure.

Read-only algorithm reference:
https://github.com/kth-competitive-programming/kactl/tree/45ee3fa7e5263c0085e2dcee42c100eb1c30121a

The fixed GitHub commit was resolved through the commits API, then the actual
file contents were fetched through its contents API and decoded in memory.
No fetched script was installed, imported, compiled or executed. Network
timeouts before that successful read did not create adopted source files.

|Complete file read|Bytes|SHA256|
|---|---:|---|
|content/graph/DirectedMST.h|2239|ab72e86d3d2ce6aa25cff5500e1c204292ffc1c9b1534ff359d70823f39d83e2|
|content/data-structures/UnionFindRollback.h|875|ca3689bce584946867eeb2c42fe24a864902ec90e125e7a3c1a9bf6ba986dc80|
|README.md|4379|40d693cca6c03c2afac5065d9f7ee1cccefec8307676341a685a562b49af7244|

DirectedMST.h credits chilli, Takanori MAEHARA, Benq and Simon Lindholm;
UnionFindRollback.h credits Lukas Polacek and Simon Lindholm. Both specific
headers explicitly say CC0. The repository README says licensing differs
by file, so no blanket repository license is inferred. The complete official
CC0 1.0 Universal legal text was separately read before implementation:
https://creativecommons.org/publicdomain/zero/1.0/legalcode.txt

KACTL uses lazy skew heaps and a rollback union-find, with pointer-based
dynamic structures and optional reverse reconstruction. ANSCORE instead
independently implements bounded layer-by-layer scans, synchronous packed
edge/node history and reverse destination replacement. It uses neither
KACTL's heap nor its union-find source or dependencies. Its performance
description and stress-test status are not claimed as ANSCORE evidence.
The independent fixture oracle enumerates original parent-edge combinations.

Semantic deduplication read the actual existing kruskal_msf RTL/contract
(undirected endpoint normalization), directed_reachability contract
(reachability/SCC), and min_cost_flow production contract. Repository searches
for arborescence, Chu-Liu/Edmonds and directed spanning trees found no existing
equivalent rooted directed minimum-cost tree service. No existing core was
modified or had its historical numerical matrix rerun.
