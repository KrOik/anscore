# Provenance and semantic boundary

Baseline: `897cf84f5861f5fada3c1a5d64127e64cdb9af92`.
Before RTL, actual searches of production RTL/README files for minimum-cycle
mean, cycle ratio, Karp, Howard and Chinese equivalents found no matching
service. The Karplus-Strong TB text hit is unrelated. Actual contracts and RTL
in signed_sssp, directed_reachability and maxflow_mincut were inspected:
signed_sssp classifies source-reachable negative cycles without an average or
cycle witness; reachability supplies unweighted SCC/cycle membership; maxflow
optimizes capacity between terminals. None optimizes total weight/cycle length
globally across disconnected signed directed components.

Read-only external review preceded RTL. Web search returned HTTP500; fixed
GitHub API/raw HTTPS reads were used, each request bounded to15seconds.

- Boost.Graph1.88.0, repository https://github.com/boostorg/graph,
  commit `54a94911e68dccf5812b32d018566566700499f3`.
  Full `include/boost/graph/howard_cycle_ratio.hpp`,23161bytes, SHA256
  `bae2fa5d5d722e84e32cdd33df26d6835d5f62a7a50d85354f2a9f804fdc45fa`.
  The complete header, including its copyright/license header, policy search,
  critical-cycle handling and all ratio/mean API definitions, was actually read.
- The graph subrepository has no root LICENSE_1_0.txt (404 was recorded during
  inspection); its header links the Boost Software License1.0. Full license
  was actually read from the matching Boost1.88.0 superproject, repository
  https://github.com/boostorg/boost, commit
  `199ef13d6034c85232431130142159af3adfce22`, `LICENSE_1_0.txt`,1338bytes,
  SHA256 `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566`.

The floating Howard policy implementation was considered as an algorithmic
alternative; epsilon comparisons and a100-iteration guard do not define this
core's exact bounded contract. Local RTL independently implements exact-length
integer DP and Karp's min/max ratio characterization, without policy iteration,
floating point or approximate termination. The independent primary oracle uses
scaled negative-cycle predicates, rational isolation and a cycle/potential
certificate; small graphs receive exhaustive elementary-cycle crosschecks.
No upstream code, license text or build script is copied, adapted or executed.
This original package uses the repository Apache2.0 LICENSE/NOTICE, with no
third-party implementation dependency. No downloaded source is needed offline.
