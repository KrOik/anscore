# Sources and offline closure

Independent original RTL, testbench and Python oracle; SPDX Apache-2.0.
No upstream source is copied, adapted into this package or executed.

Before RTL, the complete relevant upstream source and complete license were
read only from [NetworkX](https://github.com/networkx/networkx), tag
`networkx-3.5` (raw annotated tag object
`cd59914a6e46b04f006633f203ee7b4878d53159`), peeled commit
`4fa222d2fb157e1b7f8c753c9f92e5907d1ddeb4`:

| Exact file | Raw bytes | SHA256 |
|---|---:|---|
| [networkx/algorithms/euler.py](https://github.com/networkx/networkx/blob/4fa222d2fb157e1b7f8c753c9f92e5907d1ddeb4/networkx/algorithms/euler.py) |14205|`c82a8a68672115244f4d10d7abbbb57c7d885d917de3059ff52d742bdf8277a5`|
| [LICENSE.txt](https://github.com/networkx/networkx/blob/4fa222d2fb157e1b7f8c753c9f92e5907d1ddeb4/LICENSE.txt) |1763|`3cf7c3a179d817b23b8b8568211769fefdf93797d207d984b8b2fa24d0220b33`|

The complete BSD-3-Clause text and source, including directed/multigraph and
requested-source behavior, were inspected. NetworkX uses graph objects and
dynamic iterators; this package independently implements bounded synchronous
RAM, retained-edge ordinals, full32bit validation, error draining, explicit
reset ownership and atomic result publication. Its independent theorem oracle
does not import NetworkX. There is no external runtime/build dependency.

Actual whole-cores/docs semantic search for Euler, Eulerian, Hierholzer,
postman and Chinese traversal terms found no matching capability. Actual
contracts of `directed_reachability`, `graph_cut_structure` and `kruskal_msf`
were read: none emits a directed edge-exact Euler walk. Other graph optimizers
do not provide this function by renaming or changing a constant.

`files.f` is the complete production dependency closure. Add `example/trail8.sv`
for the explicit default instance. No include, ROM, sibling RTL, downloaded
library, vendor primitive or network access is required to use the module.
The Python finite runner uses only the standard library and local Icarus.
The six fixtures and generator are retained for offline reproducibility.
