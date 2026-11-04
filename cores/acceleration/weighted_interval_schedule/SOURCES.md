# Provenance and architecture preflight

Baseline: `01b92bf2f8d81fff097f1965de61edf81604ae4f` (B13).
Independent ANSCORE RTL, example, testbench, oracle and documentation are
covered by the root Apache-2.0 LICENSE and NOTICE. No third-party source is
copied, translated, adapted, executed or redistributed.

Before RTL, semantic searches of repository README/SPEC/SOURCES files for
weighted interval and interval scheduling, and inspection of the 52-package
B13 closure, `range_lock_manager` and `budget_knapsack`, found no equivalent.
Range locks maintain runtime shared/exclusive occupancy; heap and packet queues
order service; budget selection imposes a scalar capacity constraint. None
optimizes a weighted conflict-free subset of arbitrary signed time intervals.
No existing mature source is modified.

## Actual source and full-license inspection before RTL

[TheAlgorithms/Python](https://github.com/TheAlgorithms/Python), fixed commit
`574d100b7181956e9c8384552fd078165e4cc326`:

| Actual file | Bytes | SHA256 |
|---|---:|---|
| `scheduling/weighted_interval_scheduling.py` | 7394 | `106264823800abcbab76bd857554eaa42672ef71b9bb08fc1c19361e4d75bfec` |
| `LICENSE.md` | 1095 | `4395a1dc4bda1d6054c45b4d1230c709c7398e6d66f1d0aff4b22d95973bea56` |

The complete source body and full MIT license (copyright 2016-2022
TheAlgorithms and contributors) were retrieved through fixed-commit GitHub
contents API and read. The initial search endpoint returned HTTP500; a
C-Plus-Plus candidate path returned404 and was not counted as source evidence.
Only read-only HTTPS requests with15-second limits were used; no upstream
script/build ran. The Python implementation sorts by finish, binary-searches
compatible prefixes and backtracks a floating-point DP. It does not implement
this package's integer minimum-bitmap tie rule, stream protocol, RAM schedule,
error draining or reset. There is no compatibility claim or runtime dependency.

## Selected FPGA architecture before RTL

Unsigned nonnegative weight and signed integer half-open `[start,end)` with
`start < end`; adjacency is compatible. Arrival order is arbitrary. Maximize
exact total weight, then minimize the numeric original-arrival selection bitmap.
Zero weights are legal and the empty set participates in ties.

Keep original items in synchronous-read RAM. Repeatedly serially select the
unprocessed interval of minimum signed finish (index breaks equal finishes).
A second serial scan considers processed intervals finishing at/before its
start, reads their endpoint-chain DP records, and chooses the best weight/mask.
Append the current bit and weight, write one DP record and compare with the
global empty-or-chain optimum. Positive lengths ensure every predecessor has
strictly smaller finish. The minimum-bitmap tie order is preserved when adding
the same absent current bit. This gives exact optimal substructure without
moving/sorting RAM records or a combinational all-item comparator network.

An alternative sorting network has larger parallel comparison/routing cost;
insertion sort requires repeated wide record moves. The selected O(K^2)
serial engine accepts arbitrary legal endpoints with two single-read memories,
one shared sum and pair comparator, no multiplier/divider/vendor primitive.
Logical memory is `N*(2*E+W+SUM_W+N)` bits:1344 default,12672 at maxima.
Risk LOW default/MEDIUM maximum; inference and physical performance unmeasured.

No ROM, coefficient generator, include, sibling RTL, external memory or online
dependency is required. The finite matrix is frozen in TEST_PLAN.json before
the first compiler/simulator; every child is limited to20seconds. Evidence
binds current package bytes and makes no physical implementation claim.

The first N1 numerical child reached its20second limit. That check stopped
per plan, with no retry or smaller fixture. The original attempted source
hashes and commands remain in verification.json; no numerical profile passed.
A static test-driver settle correction after reset was made without rerunning
simulation. Only the unchanged production core/example syntax command is
qualified. See README for the exact LINT_PASS/TIMEOUT_NOT_RUN boundary.
