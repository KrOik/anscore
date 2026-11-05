# Exact one-dimensional balanced transport

SOURCE_ONLY; preparation, compilation, simulation, synthesis, timing, power and hardware are NOT_RUN. Original Apache-2.0 RTL and supporting sources. Read `MATHEMATICS.md`, `COST.md`, `TEST_PLAN.md`, `SOURCES.md` and the finite JSON plan before approving any execution.

For two nonnegative integer-mass histograms on the same strictly increasing signed coordinates, this core emits the canonical ascending optimal transport coupling and exact unnormalized L1 movement cost. It captures and validates the whole frame before output. Positive diagonal cells are included. A unique final summary terminates every complete frame, including invalid and empty frames.

## Parameters and complete ports

| Parameter | Default | Legal |
|---|---:|---|
| NUM_BINS (B) | 16 | 1..64 |
| KEY_W (X) | 16 | 2..24 |
| MASS_W (C) | 16 | 1..24 |
| TAG_W | 8 | 1..32 |

Derived widths: L=$clog2(B), TOTAL_W=C+L, COST_W=C+L+X, INDEX_W=max(1,L), PTR_W=max(1,$clog2(B+1)), COUNT_W=max(1,$clog2(2B)). Derived local parameters are not configurable ports.

| Port | Direction / width | Meaning |
|---|---|---|
| clk | input 1 | Rising-edge clock |
| rst | input 1 | Synchronous active-high cancellation; masks ready/valid immediately |
| s_valid / s_ready | input / output 1 | Accepted input iff both high and rst low |
| s_key | input signed X | Coordinate of this bin |
| s_source / s_target | input unsigned C each | Source and target bin masses |
| s_tag | input TAG_W | Captured on first accepted beat only |
| m_valid / m_ready | output / input 1 | Output retirement iff both high and rst low |
| m_summary / m_last | output 1 each | Both zero for a flow; both one for the unique summary |
| m_source_index / m_target_index | output INDEX_W each | Flow bin IDs; zero in summary |
| m_source_key / m_target_key | output signed X each | Flow coordinates; zero in summary |
| m_quantity | output unsigned C | Positive flow quantity; zero in summary |
| m_cost | output unsigned COST_W | Running cost INCLUDING this offered flow; final cost in summary |
| m_source_total / m_target_total | output unsigned TOTAL_W each | Captured diagnostic totals, also present in flows |
| m_flow_count | output unsigned COUNT_W | Number INCLUDING this offered flow; final total in summary |
| m_error | output 2 | bit0 unequal totals; bit1 nonincreasing coordinates; independently coexist |
| m_tag | output TAG_W | First input tag |

Exactly B accepted beats form a frame. There is no input last, keep, runtime length, CE or CDC. All coordinates must strictly increase, including zero-mass bins. Later input tags are ignored. The producer keeps every input field stable while valid and stalled. Missing inputs and output backpressure may wait indefinitely.

An invalid frame emits exactly one summary, with both diagnostic totals, both independently detected error bits and captured tag. Its cost, count, quantity, indices and keys are zero. Equal zero totals with ordered keys are valid and emit one zero-cost summary. For positive equal totals T, the integer result minimizes sum(pi_ij*abs(x_i-x_j)); a caller may interpret cost/T as normalized W1. T=0 does not define a probability distance. No rescaling, tolerance, floating point, entropy penalty, 2-D geometry, arbitrary cost matrix or partial/unbalanced transport is provided.

The owner retains capture, caches, residuals, tag and totals until summary retirement. Input ready is low on that retirement edge and becomes high for the following edge. Flow residuals and pointers change only AFTER actual flow retirement; a held flow already includes its cost/count and stays bitwise stable. Reset cancels capture, computation, a held flow or a held summary. A receiver discards any prefix without its retired summary. RAM is unreset and every new owner overwrites all B rows before any read.

`files.f` and `example/files.f` are interpreted from THIS package root, not from their own directory or repository root. The default complete-port wrapper is `example/transport16.sv`. No old RTL or protected untracked file is needed by a copied package.

## Execution gates

`AUTHOR_SEAL.json` binds source/plan/tool inventory bytes and records NOT_RUN. `prepare.py` requires a separately supplied root approval, two independent source review receipts, exact author-seal hash, and an unused attempt directory. Its one permitted future invocation uses the copied frozen model for only the 16 named frames, stores independent cut/overlap certificates and text tuples, and creates `SOURCE_SEAL.json`. It does not launch HDL. Preparation requires a root-owned outer Job20 binding; the invoking root must contain the entire preparation entry process before resume. The qualification controller uses the reviewed kill-on-close Job Object supervisor for each of its 25 individual children. Exact schemas are documented in `GATES.md`.

`run_tests.py` later requires a second root approval and exact prepared-seal hash. It validates source copies, stored certificate/fixture bytes, tool/runtime closure and fresh compiler artifacts before/after each of exactly 25 children. It never imports the preparation model. A failure retains originals, raw streams, partial artifacts and a hash archive, stops immediately, and has no retry path. No execution is authorized by this source package alone.
