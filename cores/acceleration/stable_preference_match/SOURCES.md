# Source and architecture preflight

B15 baseline: `9716da0847c26f09f4a9b856a84fc330dfb26351`.
Original ANSCORE RTL, wrapper, testbench, verifier and prose use the repository
root Apache-2.0 LICENSE and NOTICE. No upstream source or dependency is copied,
translated, adapted, executed or redistributed.

## Actual semantic inspection before RTL

The complete56-package B14 inventory and repository production RTL/README/SPEC
searches for Gale-Shapley, stable matching/marriage and Chinese equivalents
found no preference-stability service. Actual `bipartite_match` and
`min_cost_assignment` contracts were read: they optimize cardinality and total
cost respectively, rather than absence of a mutually preferred blocking pair.
Runtime strict preferences on both sides and proposer-optimality among stable
bijections add a distinct capability. Existing sources remain unchanged.

## Actual upstream implementation and full license read before RTL

[TheAlgorithms/Python](https://github.com/TheAlgorithms/Python), immutable
commit `574d100b7181956e9c8384552fd078165e4cc326`:

| File | Bytes | SHA256 |
|---|---:|---|
| `graphs/gale_shapley_bigraph.py` | 1991 | `98070bb77f0bcf03c9514995d7f9c22d23cbfb03581cccd1598c882b3ad38322` |
| `LICENSE.md` | 1095 | `4395a1dc4bda1d6054c45b4d1230c709c7398e6d66f1d0aff4b22d95973bea56` |

The entire implementation body and complete MIT license, copyright2016-2022
TheAlgorithms and contributors, were retrieved through fixed-commit GitHub
contents API and read before RTL. The search endpoint failed HTTP500;
read-only HTTPS requests with15-second limits supplied the actual files.
No unknown script, build or downloaded code ran. The software keeps Python
lists, searches receiver preference positions and processes a donor queue.
It has no hardware stream, RAM ownership, full-width validation, reset,
backpressure, fixed cardinality or diagnostics contract. No API compatibility
is claimed; its illustrative medical terminology is not a local use claim.

## Selected architecture before RTL

Static equal side sizes N1..32; every agent supplies a complete strict
permutation of the opposite side. Input position implies side/agent/rank;
each32-bit partner is range-checked before narrowing, duplicate row entries
and first/last marker errors reject the whole fixed2N²-token transaction.

Two synchronous preference RAMs retain proposer order and inverse receiver
ranks. Small indexed register tables retain next proposal rank and both mate
maps; free bitmaps own those entries. Initialize one agent per clock, serially
scan for the lowest free proposer, read its next choice and compare receiver
ranks in separate cycles. Each preference pair is proposed at most once.
Receivers only improve, so no rejected pair belongs to any stable matching;
termination yields the unique proposer-optimal stable bijection. Replay is
proposer-ordered with both partners' ranks and a shared proposal count.

A parallel all-pair matching network incurs unnecessary routing and preference
comparators at these bounded sizes. The serial design uses two RAM read ports,
small scalar/indexed register state, no multiplier/divider/vendor primitive or
external memory. Preference RAM is2*N²*INDEX_W bits:384default/10240max.
The small next-rank/mate tables total N*(COUNT_W+2*INDEX_W):80/512bits.
Qualitative risk LOWdefault/MEDIUMmax; no physical measurements are implied.

The independent verifier directly checks bijection/blocking pairs. A rejection
certificate is checked by induction: receiver r prefers winner w to loser l,
and all partners w prefers to r were previously certified impossible. Then
(l,r) cannot belong to any stable matching. At completion every partner better
than a returned mate must be certified impossible. This proves proposer
optimality without reproducing the RTL queue/scan/update algorithm. Small N
also enumerates every bijection and all stable solutions independently.

All manifests/examples are local. The frozen finite plan precedes every tool;
each compiler/simulator child is limited to20seconds. A timeout is terminal,
with no retry, fixture reduction or timeout increase. B14's unrelated terminal
interval-scheduler check is retained untouched.
