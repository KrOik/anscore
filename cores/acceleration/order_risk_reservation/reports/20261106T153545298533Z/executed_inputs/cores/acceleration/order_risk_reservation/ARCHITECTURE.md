# Structural budget and invariants

Applied fpga-rtl-pareto before writing RTL. No device/Fmax target was supplied.
The service is serialized and bounded; it is not advertised as line-rate risk.

The existing position ledger already implements signed64 positions, directional
open totals, ticket capacity, exact65-bit endpoints and two synchronous RAMs.
Duplicating it or adding an independent signed arithmetic engine would increase
both verification and accounting risk. This wrapper instead adds token/lifecycle
metadata and uses row index as the ledger's private64-bit ticket. The full public
112-bit token is never shortened, hashed into an unchecked identifier or exposed
as the private ticket. Only one owner can access either metadata or ledger.

An all-key CAM was rejected: a single112-bit comparison per scanned row fits
the small bounded table without ORDERS-way comparison/reduction. Metadata uses
one variable-index read and one selected write; reset touches occupied/count,
not payload arrays. Logical per-row storage is112+32+32+1+2+1=180bits including
occupied,1440bits default8/5760bits max32, plus scalar registers/response buffers.
The unchanged ledger adds272*CONTEXTS+104*ORDERS payload bits,1920 default/
7680 maximum, plus validity, count and private response registers. Payload RAM
packing/metadata muxes are a qualitative MEDIUM resource risk. These figures
are logical storage counts, not mapped LUT/FF/BRAM/power measurements.

NEW reserves before publishing success. ACK/CANCEL_REQUEST/CANCEL_REJECT verify
the saved ledger row through GET_TICKET before updating phase. A FILL preserves
pending-cancel while remainder survives. A partial CANCEL_ACK performs CANCEL
then RESERVE with the same private ticket and strictly smaller positive quantity.
No public command interleaves; account position cannot change in the gap, lower
open quantity preserves both endpoint inequalities, and CANCEL frees capacity.
Expected validation failures occur before mutation. Any unexpected private reply
forces INVALIDATE; no rollback is asserted after a private write.

No multiplier/divider/DSP is added. The expected wrapper bottleneck is the
112-bit token compare/read selection, plus the inherited65-bit position endpoint
comparisons. They are separated by FSM stages. Token scan consumes at most
ORDERS clocks. Each child command scans at most ORDERS rows with two clocks per
live row, account reads/writes and response ownership overhead. A conservative
source-level normal-operation response-valid envelope is8*ORDERS+48 clocks;
partial cancellation has two child transactions. This excludes reset and all
external output stalls and is a conservative design budget, not measured latency
or a timing constraint. First output retirement is another edge. Persistent
backpressure means there is no unconditional whole-transaction deadline.

Only reset/CLEAR starts a new epoch. INVALIDATE keeps holds and actual positions.
Release of cancellation risk requires explicit confirmed decrement; a local
cancel request or cancel reject cannot change the ledger's quantity or position.
This remains true when the eventual venue message is delayed indefinitely.
