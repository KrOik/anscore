# Fixed provenance, semantic review and offline dependency

Baseline548ecff2b34281ec7b6f3306ba1c8d3af07f246d. Original wrapper/RTL,
edge-deletion BFS oracle and testbench are ANSCORE Apache-2.0 contributions.
No external implementation was copied, translated, installed or executed.
Full repository LICENSE/NOTICE bytes are included unchanged.

Actual repository semantic reads covered directed_reachability (reflexive
closure/SCC/DAG flags), directed_dominators (root-specific mandatory paths),
graph_cut_structure (undirected vertex/edge cuts), and directed minimum
arborescence (weighted rooted spanning tree). No existing core returns the
minimal edge-equivalent DAG. Full-text searches for transitive reduction and
its Chinese name found no matching production implementation. The new core
actually instantiates directed_reachability rather than replacing mature RTL.

Unchanged dependency:
`../directed_reachability/rtl/directed_reachability.sv`, SHA256
`f2d80d7a1e72f0048a028449c8156f20353468465c1ea1ecdd2a5b84b2a198cf`,
original feature commit afc7756d016f3a459dd31123c17c9fa50f87bd9a, inherited in
the published B26 closure. Both production file lists name it explicitly.
The new seal separately binds this external-to-package committed source.
New tests exercise the combined reduction service with their own fixed input;
the inherited reachability numerical matrix is never launched.

The web endpoint returned HTTP500 before implementation. Direct read-only
GitHub/raw requests then obtained actual fixed NetworkX source and the entire
BSD3 license. Data was read with explicit UTF8 after a local default-codepage
read error; no remote module or script was executed. Fixed repository:
https://github.com/networkx/networkx/tree/2acf1590f82757c01a57b81b8c5dfb79e60aa416

|Actual source|Bytes|Git blob|SHA256|
|---|---:|---|---|
|LICENSE.txt|1763|100b4bffb00abd785f61fca42fea2ab74a70d7f7|5b433b90f755eb9bbd06feff1d1a4f5f232c5208a185694199e45fa95d762792|
|networkx/algorithms/dag.py|45070|c757afb96f1398d64ae63a5f682e46031a38ff8d|cb61e1666d3ea2545969b828f717338ec59ff0e6d2786fbe5499773c8121f5c1|

The entire transitive_reduction function was inspected. It rejects non-DAGs,
forms descendant sets with DFS, and subtracts descendants from successor sets.
The BSD3 license was read in full: source/binary notices, disclaimer and
non-endorsement conditions apply to redistribution. This is a feasibility and
algorithm comparison, with no imported NetworkX code or runtime dependency.
The hardware uses synchronous captured-row RAM and a scalar scan; the local
reference independently deletes each candidate edge and runs BFS. No upstream
API compatibility, test coverage or hardware implementation claim is made.

Dependency/NOTICE closure is offline. The inherited compiler timeout and
NOT_RUN boundaries remain unchanged. No synthesis, PnR, STA, board or expanded
numerical regression is part of this package.
