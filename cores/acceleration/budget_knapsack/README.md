# Exact budgeted 0/1 selection

`budget_knapsack` selects a subset of a finite stream of unsigned cost/value
items. It maximizes total value subject to total cost <= the captured capacity.
Ties choose minimum total cost, then the smallest numeric selection bitmap,
where bit i denotes the ith retained item. It replays every retained item with
its selection bit, so a caller can route both selected and rejected items.

Zero cost, zero value and zero capacity are legal. Each item can be selected
at most once. An item whose cost exceeds capacity is legal but cannot be
selected. The empty subset is always feasible. A nonempty all-zero frame
therefore selects no items. This is an exact integer optimizer, without
fractional packing, approximation or signed utility.

## Interface and transaction contract

All ports use rising-edge `clk`. Synchronous high `rst` must span a rising
edge and cancels collection, computation or held output. Public ready/valid
are gated low during reset. There is no CE, CDC, memory bus or bus-error
protocol. A CE-qualified stream needs an explicit adapter.

An input transfers on `s_valid && s_ready`; the producer must hold the entire
token stable until acceptance. `s_keep=1` appends one item. Masked tokens do
not consume item capacity. The first accepted token captures unsigned 32-bit
`s_capacity` and opaque `s_tag`, even when masked. Later capacity/tag fields
are ignored. An accepted `s_last` closes the frame even when masked. A missing
tail waits indefinitely until reset. All cost/value fields are unsigned
integers; there is no fixed-point scaling.

The collector accepts one beat per clock. It continues accepting excess items
through the tail so an invalid frame can drain. One frame is in flight:
ready stays low during initialization, optimization and output. Output
transfers on `m_valid && m_ready`; valid and every output field remain stable
while stalled. The next frame can transfer on the edge after the final output
is consumed. Computation advances independently of input valid/output ready.

| Output | Normal nonempty frame |
|---|---|
| `m_keep` | One for every retained item, selected or otherwise |
| `m_index,m_cost,m_value` | Original item index, cost and value in input order |
| `m_selected` | Whether that item belongs to the optimal subset |
| `m_count` | Total retained item count, repeated on every output |
| `m_total_cost,m_total_value` | Optimal totals, repeated on every output |
| `m_first,m_last` | First/final replayed item |
| `m_capacity,m_tag` | Full first-token capacity and tag, repeated |
| `m_error` | Zero |

Error bit 0 means more than MAX_ITEMS retained items; bit 1 means the first
capacity exceeds MAX_CAPACITY. Capacity is checked before narrowing. Errors
are independent and sticky through the tail. **Any error rejects the entire
frame**, including its retained prefix. It emits one masked status token:
keep/selected/index/cost/value/count/total_cost/total_value are zero, first and
last are one, and the captured capacity/tag plus both error bits are retained.
An empty valid frame emits the same zero status token with error zero.
Output fields are unspecified when valid is low. Reset clears control/read
and public scalar registers; item and DP memories are not reset. Every memory
record is initialized or overwritten under frame ownership before it is read.

## Parameters and numeric bounds

| Parameter | Default | Legal values |
|---|---:|---|
| MAX_ITEMS | 16 | 1..64 |
| MAX_CAPACITY | 63 | 0..255 |
| COST_W | 8 | 1..16 |
| VALUE_W | 16 | 1..24 |
| TAG_W | 8 | 1..32 |

Derived widths are INDEX_W=max(1,ceil(log2(MAX_ITEMS))),
COUNT_W=ceil(log2(MAX_ITEMS+1)),
BUDGET_W=max(1,ceil(log2(MAX_CAPACITY+1))), and
SUM_W=VALUE_W+ceil(log2(MAX_ITEMS)), with zero growth at MAX_ITEMS=1.
The maximum value MAX_ITEMS*(2^VALUE_W-1) fits SUM_W. The candidate addition
retains an extra carry before storing the proven bounded result. Candidate
cost uses max(COST_W,BUDGET_W)+1 bits and narrows only after feasibility is
established. All stored used costs are <= their DP budget. Illegal static
parameters fail elaboration through unresolved
`budget_knapsack_invalid_parameters__see_README`.

## Architecture, latency and resource risk

Items use a synchronous read memory of `{cost,value}`. A second synchronous
memory stores `{selection_bitmap,used_cost,total_value}` at each budget.
The core clears budgets 0 through runtime capacity, visits items in ascending
order and budgets in descending order, and uses three clocks per candidate:
read current record, read base record, compare/update. Both reads precede the
write even for zero cost, so that item is added exactly once.

An update wins on larger value or equal value with smaller used cost. Exact
ties retain the old record: a new candidate has the newest, highest item bit,
so its mask exceeds every old mask. Together with the same invariant for the
base record, this proves the global minimum-mask tie rule. An oversized item
skips its budget sweep. The final record supplies totals and a bitmap for
synchronous item replay. No multiplier, divider, vendor primitive, external
RAM, ROM initialization data or runtime dependency is required.

Let K be the retained item count, C the valid captured capacity, and
`Q = sum(C-cost_i+1 for each cost_i <= C)` over all retained items. For a
normal nonempty frame, first result valid appears
**C + 2*K + 3*Q + 4 clock periods after the accepted tail edge**. Empty/error
status valid appears immediately after that edge (zero periods). Earliest
transfer is the next rising edge. Subsequent items appear every two periods
without sink stalls. Output stalls extend completion; input cannot overlap
optimization or replay. These are controller schedules, not measured Fmax.

Logical memory bits, excluding scalar/read/output registers, are:

```text
(MAX_CAPACITY+1)*(MAX_ITEMS+BUDGET_W+SUM_W)
  + MAX_ITEMS*(COST_W+VALUE_W)
```

This is 3,072 bits by default (2,688 DP + 384 item) and 28,672 bits at all
maximum parameters (26,112 DP + 2,560 item). There is no array reset or
combinational array scan. Wide DP records, tool-dependent RAM inference and
serial runtime dominate scaling. Qualitative resource risk is **LOW** at the
default and **MEDIUM** at maximum parameters; RAM mapping, LUT/FF counts,
device fit, timing, power and throughput frequency are unmeasured.

`files.f` is relative to this package root. `examples/select16.sv` exposes all
default ports and is a syntax-checked instantiation, without a connected
application. From the package directory:

```text
iverilog -g2012 -Wall -tnull -s budget_knapsack -s select16 -f files.f examples/select16.sv
```

## Finite evidence and maturity

From the repository root:

```text
python -B cores/acceleration/budget_knapsack/sim/run.py
```

Only Python's standard library and existing Icarus/vvp are needed. Each tool
child is limited to 20 seconds. Temporary vectors/executables are automatically
removed. `verification.json` retains commands, diagnostics, vector hashes and
six exercised source hashes; the cumulative snapshot also binds this document
and SOURCES.md. Source files use LF through the local `.gitattributes`.

The independent oracle keeps exact-cost dictionary frontiers with copied
item stages, then minimizes `(-value,cost,mask)`. It does not use the RTL's
best-per-budget descending in-place schedule. For small normal frames an
exhaustive subset oracle cross-checks the complete optimum and bitmap.

Eight actual profiles `(MAX_ITEMS,MAX_CAPACITY,COST_W,VALUE_W,TAG_W)` are
`(1,0,1,1,1)`, `(1,3,2,2,1)`, `(4,3,1,1,3)`, `(5,7,4,5,8)`,
`(16,63,8,16,8)`, `(17,31,6,9,16)`, `(2,255,1,1,1)` and
`(64,255,16,24,32)`. They passed 692 frames and 2,917 output tokens, including
507 exhaustive-subset cross-checks. The small domain enumerates every ordered
cost/value-binary sequence of lengths 0..3 at capacities 0..3. Fixtures cover
zero cost/budget/value, value/cost/mask ties, full capacity, capacity errors,
excess items, masked metadata/tails, changed later metadata, maximum sums and
seeded random frames. Every output field and exact first-valid latency is
checked, including the maximum 64-item/255-capacity profile.

Independent source/sink drivers create consecutive offers and real source
stalls during preceding-frame computation/replay. Each result, including
singleton and status-only results, is held for three active clocks. Twelve
immediate reset probes per profile (96 total) cover every controller state,
partial collection and a held output with the next input pre-offered. These
cancel at the observed phase without another active edge. Ten illegal static
parameters must fail elaboration. All 28 tool records met their expected exit
status; positive compile/simulation diagnostics were empty.

Maturity is **LINT_PASS + UNIT_SIM_PASS**, with all hardware behavior
**HW_UNVERIFIED**. The instantiation example has syntax-only evidence. No
synthesis, PnR, STA, board test or expanded regression has run. These finite
checks do not prove all legal parameter/input combinations.
