# Exact minimum-weight set cover

`exact_weighted_set_cover` chooses a subset of runtime sets whose union contains
every requested target bit. It returns the globally minimum unsigned total
weight and a complete selection bitmap. Among equal weights the numerically
smallest bitmap wins. This is an arbitrary coverage constraint, distinct from
the scalar capacity/value optimization in `budget_knapsack` and the pairwise
compatibility constraints in `maximum_clique` / `exact_graph_coloring`.

## Interface contract

| Parameter | Default | Legal integers |
|---|---:|---|
| NUM_SETS = R | 8 | 1..16 |
| UNIVERSE_W = U | 16 | 1..32 |
| WEIGHT_W = W | 8 | 1..16 |
| TAG_W = T | 8 | 1..32 |

All data is unsigned. The sum width is `C=W+ceil(log2 R)` (W for R1),
sufficient for `R*(2^W-1)` without saturation or wrap. A command handshakes
`c_valid && c_ready` and captures `c_target,c_tag`. Exactly R subsequent row
handshakes `s_valid && s_ready` load `{s_members,s_weight}` in row-index order.
Bit i of `m_selection` selects row i; universe bit j identifies column j.
Columns outside the target are ignored by feasibility. Empty rows, duplicate
rows and zero weights are legal. Target zero returns the empty subset with
weight zero after still consuming all R rows. The complete selected union may
contain unrequested columns. No external storage or generated data is needed.

Accepted LAST before row R-1 immediately ends capture and reports error1.
An accepted final row without LAST ends capture and reports error2. These are
exclusive errors; the command/row framing has no drain beyond its accepted
terminator. Every command produces one response. Missing rows leave capture
open. The caller must not send surplus rows for a terminated command; the next
row belongs to the next accepted command. There is no row FIRST or row tag.
An error returns feasible0, selection0, weight0 and the owning command tag.
An error-free infeasible instance also returns feasible0/selection0/weight0,
with error0. Feasible results always carry the full exact optimum and witness.

One rising-edge clock, synchronous active-high reset, ordinary ready/valid,
no CE or CDC. Commands and rows each hold valid and their complete payload
through acceptance. The row channel is ready only after command acceptance;
commands are ready only in IDLE. A transaction owns load, search and held
response. All response fields remain stable while blocked. Row capture has
II1; the next command can transfer on the edge after response retirement.
Input gaps and output backpressure have no upper bound. There is no output
LAST because each response owns the complete answer. Parameters are static;
there is no live configuration bank, memory bus or error retry mechanism.

Reset immediately gates all public ready/valid low; its active edge cancels
partial load, search, saved pending branches or held normal/error response.
After release the service is IDLE with no old response. RAM contents/read-data
are not reset. Every successful search loads all R current rows and every
pending restore follows a same-search push/read. Invalid captures never search.
Reset generates no response and does not clear RAM with an array reset tree.

## Architecture and bounded work

A shared OR/add datapath performs include-first depth-first search. Each
nonterminal prefix synchronously reads one row, pushes its exclude child to
an explicit synchronous stack, and processes the include child in registers.
A completed cover immediately updates `(weight,bitmap)` in lexicographic
order. No extension can improve it: weights are nonnegative and adding any
extra selected bit strictly increases the numeric bitmap. An incomplete node
whose accumulated cost is greater than the best cost is safely pruned. Equal
cost is never pruned, preserving zero-weight and bitmap ties. Exhausting all
pending nodes proves the optimum or infeasibility. No recursive hardware or
combinational exponential circuit is instantiated.

The row bank is R words of U+W bits with one synchronous write/read; writes
occur only in LOAD and reads only at a nonterminal EVAL. The pending bank is
R words of `D+U+C+R` bits, `D=clog2(R+1)`, holding depth/union/cost/selection.
It has one synchronous write in CHILD and one synchronous read in POP, used
in RESTORE. The maximum stack depth is R. No read/write collision is consumed,
no whole-array asynchronous read exists, and the two banks have separate ports.
Small banks may map to registers; BRAM inference is unmeasured.

Logical RAM bits total `R*(2U+W+D+C+R)`: **504 default /1936 maximum**.
Scalar, response and read-data declarations total `4U+W+4D+4C+4R+T+7`:
**179 default /447 maximum**. There are no multipliers, dividers, DSP
primitives, vendor macros or external dependencies. The anticipated paths are
the C-bit add/compare, U-bit OR/cover compare and small state/address muxes.
Risk is LOW default /MEDIUM maximum; exponential service time remains a real
limit. These are structural counts, not synthesized resource measurements.

Let I be the number of nonterminal prefixes. Search makes `2I+1` EVAL visits,
I CHILD clocks, I successful POP/RESTORE pairs and one final POP/FINISH pair.
Exact latency from final row acceptance to first result-valid is `5I+3`,
bounded by `5*2^R-2`: **1278 default /327678 maximum** clocks. Errors take
exactly one clock. A cover of the empty target takes three clocks. Response
transfer needs another edge; the next transaction also loads R rows. These
bounds exclude caller gaps and stalls and do not claim a hardware clock rate.

## Offline use and finite qualification

From this directory, `files.f` supplies the sole production RTL source.
`example/cover8.sv` forwards the default complete service interface.

```text
iverilog -g2012 -Wall -tnull -s exact_weighted_set_cover -f files.f
iverilog -g2012 -Wall -tnull -s cover8 -f files.f example/cover8.sv
python -B sim/run.py
```

The local runner requires Python standard library and local Icarus only.
Root LICENSE/NOTICE apply to this original local Apache-2.0 implementation.
No upstream code, build, Python library, ROM, network or sibling RTL is needed.
SOURCES.md records the fixed complete upstream/source/license reads and actual
semantic dedup. Local attributes preserve LF bytes for reproducible hashes.

Before the first HDL tool, TEST_PLAN.json fixes six R/U/W/T profiles:
1/1/1/1,2/3/2/3,4/4/3/5,6/9/8/8,8/16/8/8,16/32/16/32. The matrix is29
children: version, top/example syntax, six compile/main/reset triples and
eight expected parameter rejections. Every child is limited to20 seconds;
timeout is terminal with TIMEOUT/NOT_RUN evidence, never smaller vectors or
more time. Concrete ordinary failures can be repaired only with the identical
matrix and preserved original plan/source/receipt evidence. A successful
matrix is not rerun. No synthesis, PnR, STA, board or expanded regression.

The independent primary oracle uses iterative reachable-coverage DP, retaining
the optimal `(weight,bitmap)` for each covered-target mask. It does not follow
the RTL stack/traversal/pruning. All cases through R6 are independently
crosschecked by direct subset enumeration. A separate DFS schedule certificate
checks exact operation counts and latency, never supplies the primary optimum.
Every input/command/oracle image is hashed in the frozen plan. Profiles R1/R2
exhaust all row/weight/target bitpatterns; larger profiles include seeded and
column-permuted cases, zero-weight ties, empty targets, duplicate/empty sets,
mandatory sets, greedy traps, full-width weights and infeasible coverage.
The maximum profile numerically exercises a complete unpruned tree and a
full-weight mandatory-all witness. No advertised maximum is compile-only.

TB checks every output field, complete current row-bank images, exact latency,
branch/pop counts and every search node's prefix bounds, recomputed weight and
union. It presents actual subsequent commands and row tokens during busy/held
periods, checks both complete source bundles through acceptance, and checks
held results. Twelve immediate reset groups per profile cover all8 reachable
FSM states, partial loading, maximum stack, early/missing-LAST error holds.
At R1 early LAST is impossible and that group explicitly uses missing LAST.
Every cancellation completes a fresh full-R-row zero-weight cover, verifies
all current rows and the exact min-bitmap witness, holds and retires its result.
This is finite functional/protocol evidence, not exhaustive timing schedules,
formal verification or hardware validation. Current receipts own actual status.
