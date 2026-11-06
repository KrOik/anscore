# Arithmetic, memory and schedule contract

The default design trades service rate for explicit single-port error-memory
transactions and bounded line storage. An II1 design would need multiple error
bank read/write ports and carefully pipelined recursive error forwarding. The
selected core owns one pixel at a time and finishes all error writes before
presenting its output, making arbitrary output stalls independent of arithmetic
state. The existing buffered serpentine module is retained for its different
order/storage contract. No measured physical resource/performance comparison is
available.

## Width proof

Let `A=16*(2^BITS-1)`. Clamping implies corrected in[0,A]; either palette level
also lies in[0,A], so residual is in[-A,A], even for narrow palettes. A rounded
contribution of integer weight k has magnitude at most `A*k/16+1/2`. A next-row
RAM location accumulates at most weights1+5+3=9, so its magnitude is at most
`9*A/16+3/2`. A separate right carry is at most `7*A/16+1/2`. Incoming total
therefore has magnitude at most `A+2`. The unclamped signed sum is between
`-(A+2)` and `2*A+2`, fitting signed `EW=BITS+6` since
`2*A+2=2^(BITS+5)-30 < 2^(BITS+5)-1`. Every intermediate partial addition also
fits that width. Error RAM/error read/carry/residual/combined all use EW signed.
Signed conversion of RAW and palette Q4 includes two explicit leading zeros.

Weighted magnitude uses unsigned EW; full product-plus-half uses EW+4 bits
before shifting4. Its sign is reapplied after unsigned rounding. The largest
allowed weight7 fits the product width. The midpoint comparison widens corrected
to EW+1 before doubling; `low+high` first widens to BITS+1, then appends4 zeros.
No overflow or intermediate level rounding is allowed. Final m_data is exactly
one of the snapshotted BITS-wide palette values.

16-bit x/y suffice for4096 pixels per axis; clear_address16 covers8192 error
locations. Memory addresses17 include row-bank base and neighbor offset. An
out-of-range neighbor's wrapped combinational address is never read or written.
No generic divider, frame-sized loop, vendor primitive or external memory is
required. Small variable4-bit weight multiplication may map to logic; no DSP
mapping or resource count is asserted.

## RAM and lifecycle

One logical synchronous single-port error RAM stores `2*WIDTH*EW` bits: default
3584 bits, maximum147456 bits at4096/BITS12. A CLEAR pass writes zero to all
2*WIDTH addresses after each valid command, including after any reset or fault.
Control reset does not reset RAM or error_q. Each error_q use follows a completed
READ or NREAD. There is no read/write collision and no dependency on RAM
read-during-write behavior.

For row y, bank y%2 is read and cleared at each consumed pixel. The opposite bank
accumulates next-row errors with sequential read-modify-write transactions.
Before that bank is used as a future destination again, every old location has
been consumed and zeroed. This invariant applies to WIDTH1 and HEIGHT1. Carry
contains only the preceding pixel's right contribution; it is zero at row start
and on every command/reset. Neighbors of the final row are skipped entirely.

Output HOLD follows completion of every next-row write. HOLD has no RAM writes,
coordinate changes or palette changes. Last output consumption moves to DONE;
DONE acknowledgement moves to IDLE. A new command can only transfer on a later
edge. Invalid commands/faulting pixels do not write output. This makes the
held-output and completion fences part of transaction ownership.

## Enabled-edge service budget (there is no CE)

At command acceptance IDLE enters CLEAR; exactly2*WIDTH subsequent rising edges
clear RAM before INPUT can accept a sample. For a legal pixel accepted at edge t:
READ at t+1 fetches its accumulated row error; QUANT at t+2 clears that location,
selects the level and computes signed contributions. A final-row pixel then
presents output valid immediately after t+2. Other rows execute SELECT for
neighbors0..3; each in-range next-row neighbor adds NREAD/NWRITE two edges.
Output becomes valid after `t+6+2*K`, K=number of in-range next-row neighbors,
so interior pixels use t+12. Earliest output handshake is the next edge.
After output handshake the core re-enters INPUT. Thus no-stall source acceptance
interval is `8+2*K` clocks (interior14), or4 clocks on the final row. WIDTH1 has
only down, K1. An input pause or output stall extends completion unboundedly.

The RGB example inserts one converter stage before diffuser acceptance.
RGB is accepted only when the gray slot is empty and the diffuser is INPUT;
the unchanged converter registers its gray output on that edge, and the next
edge transfers it to the diffuser and clears converter valid through CE.
No overlapping source acceptance/gray consumption is allowed. It adds one edge
to first-pixel latency and one to each source initiation interval, relative to
direct grayscale acceptance. No source token is owned beyond an error fence.

No hardware frequency, FPS or real-time claim follows from these RTL schedules.
Qualitative risk: memory LOW at default and MEDIUM at4096 columns (device RAM
mapping unmeasured); arithmetic LOW/MEDIUM; control MEDIUM due to recursive
error lifecycle; CDC absent. No array of whole-frame pixels is present.

## Frozen finite verification scope

Four profiles:1x1/B8/T1,7x5/B10/T8,17x9/B12/T32 and actual RGB16x7/B8/T12.
Each has10 literal-input families with independent expected output: extremes,
gradient, checkerboard, exact midpoint, narrow/full palettes and seeded random.
Each simulation checks19 successful frames (10 plus9 post-reset recoveries),
three marker faults, two invalid palettes, nine live resets, command snapshot,
output/DONE stability, source gaps and output stalls. Multisample profiles also
check22 first outputs occur before final source acceptance, including partial
fault frames. Reset targets CLEAR, INPUT, READ, QUANT, neighbor selection,
neighbor read/write, held output and DONE; thin height substitutes reachable
READ/QUANT states for absent neighbor stages. A command pending behind held
output is explicitly blocked. Whole-frame oracle fields are independent of
RTL bank/clear schedule. Static maximums receive syntax only; all child limits
and stop conditions are in PRECHECK_PLAN.json and the reviewed fresh runner.
