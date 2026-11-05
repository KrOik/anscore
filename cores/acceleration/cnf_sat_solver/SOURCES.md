# Source and license preflight

All delivered RTL, example, TB, oracle and runner are original ANSCORE work,
Apache-2.0 under the included LICENSE/NOTICE. No fetched source is copied,
imported, built or executed. Production closure is one local RTL file.

Read-only external preflight used the original MiniSat repository:
https://github.com/niklasso/minisat/tree/37dc6c67e2af26379d88ce349eb9c4c6160e8543

The GitHub commits/contents APIs resolved and fetched the fixed revision.
The entire MIT-style LICENSE was read, including the attribution condition
and warranty disclaimer. Solver.cc's propagation, backtracking and search
methods were inspected; the full files were retrieved and hashed in memory.

| Retrieved file | Bytes | SHA256 |
|---|---:|---|
|LICENSE|1142|c75f5063560674728fcfa7b9b291d26a3a8b9436a0d9940eadc81aab7779d62b|
|minisat/core/Solver.cc|35026|bca15c3ad1bc29bfd2aa1609d707b1f0f516e17c53164b593c102a8b981b3792|
|minisat/core/Solver.h|24060|47f0330cf08eea66852015be00c53c92b1454eee9d549e53f09feaa25c8f03b2|

MiniSat uses watched literals, dynamic clause allocation, conflict analysis,
activity heuristics, learned clauses and restarts. This independently designed
small FPGA service instead scans a fixed synchronous clause bank and saves
complete alternative assignments in bounded synchronous RAM. It does not
adopt MiniSat code, dependencies, heuristics or performance claims. Its oracle
is complete truth-table evaluation, not either solver's search implementation.

The web search/open service returned an unavailable-endpoint error. A default
Windows-proxy HTTPS request separately timed out during SSL before retrieving
the reference. An explicit direct HTTPS opener then completed the fixed GitHub
API reads above. Neither unsuccessful network operation was an HDL execution
or a retry of any frozen package/snapshot check.

Semantic dedup searched all existing cores for DPLL, CNF and satisfiability and
read the actual exact_weighted_set_cover, exact_graph_coloring and maximum_clique
contracts. Those expose union/weight or graph-only constraints, without a
general signed multi-literal CNF interface or SAT/UNSAT service. No prior core,
historical evidence, original dirty file or original untracked asset is changed.

The first attempted compiler invocation selected a stale Chocolatey shim,
before actual Icarus or RTL parsing. The original29-command plan and33-file
failure closure are preserved verbatim. The explicit repair selects the existing
local OSS CAD Suite tools directly and records their actual executable hashes;
it adopts no tool binary, changes no DUT/TB/oracle/fixture and performs no
network installation. Production dependencies remain the single original RTL.
