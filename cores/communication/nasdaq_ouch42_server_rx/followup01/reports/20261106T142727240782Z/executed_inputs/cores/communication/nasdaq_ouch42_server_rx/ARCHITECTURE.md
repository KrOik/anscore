# Architecture and source review boundary

Semantic repository review found no OUCH decoder. Exact OUCH/order-token and
replacement-token searches covered source/README paths across the repository;
unrelated prose matches were inspected. Existing MoldUDP64/ITCH reception and
ITCH order-state/book assets operate on market-wide IDs, whereas this decoder
normalizes account-specific112-bit tokens and acknowledgement/reject lifecycle.
The new integration reuses the canonical B45 Soup receiver and its real FIFO;
no parallel TCP/framing implementation or copied FIFO is introduced.

One80-byte cache is cheaper than a generic packet store and keeps fixed wire
offsets explicit. A selected byte writes per accepted beat; there is no640-bit
shift every cycle. Parsing directly into a second wide result register would
duplicate state and complicate rollback; a fixed-slice combinational decoder
instead uses the held cache. RECEIVE -> CHECK -> RESULT separates final-byte
storage from validation and prevents partial publication. Ready has no path
from public result readiness into input readiness. Output multiplexing plus
error masking is an unmeasured timing risk. There is no DSP/divider arithmetic.

Core logical state is640 data bits plus16 count,2 state,3 status and TAG_W tag
bits (661+TAG_W in total). The cache is a wide-read fixed-register structure;
no BRAM mapping is promised. The720-bit public record is combinational, with
zeroed absent fields. Count saturates; only values below80 index the cache.
All integer fields are unsigned exact network-order values, with no arithmetic
overflow or price rescaling. Timestamp64,token112,reference64,match64 and
quantity/price/time32 are retained without signed conversions or rounding.

Wrapper state is wires only. Soup's committed FIFO publishes S payload only
after complete frame reception. Its completion follows payload drain. The
decoder holds its result until the same public retirement that acknowledges
Soup; Soup cannot admit a later prefix meanwhile. An empty S takes the explicit
zero-length branch and needs no fake data beat. Controls never create decoder
ownership. Reset masks both sides and cancels their state together.

The reused FIFO's logical payload is approximately10*FIFO_DEPTH bits before
pipeline/control slots:1280 at default128 and40960 at maximum4096. Its physical
RAM organization and all LUT/FF/Fmax/power results remain unmeasured. Soup's
store/commit/drain and completion ownership add latency beyond the standalone
N+2 start spacing. This package makes no continuous-frame or line-rate claim.
Arbitrary source/sink stalls have no completion bound.

The new byte-offset Python oracle does not inspect HDL. It uses Python unsigned
integers and a separate named-field pack order. Exhaustive checked-enumeration
values, every nonempty truncation, one-byte extension per type, all250 other
types, raw byte identifiers, integer extremes and65535/65536/70000-byte drain
cases form2557 core vectors. Core TB adds partial/CHECK/held-reset cancellations
and three valid recovery events. Soup's29 vectors include login/debug/heartbeat,
all six payloads, empty S, malformed payload recovery, unsupported OUCH,
capacity, terminal rejection, prelogin fault and unsigned64 exhaustion. The
wrapper TB attempts a future heartbeat prefix throughout every held completion
and separately cancels uncommitted Soup, partially drained decoder and held
joined ownership, with full login/event recovery after each.

The finite runner is new reviewed source. It archives the complete exact source
closure, plan and gate, pins tool bytes, checks baseline HEAD by reading Git
metadata only, creates one exclusive guard and never retries. Each target has
20 seconds including spawn/PID persistence, with a post-wait elapsed check.
Cleanup gives the tree helper5 seconds with the same post-wait check, issues
independent nonwaiting helper and target kills despite cleanup exceptions,
then uses one sole2-second target observation and a final nonwaiting helper
poll. Surviving PID/raw state remains explicit. PID, exit and raw/hash evidence
are durable before marker, vector receipt or image interpretation. A failed
child stops the finite plan; no old attempt is imported, rerun or cleaned.
