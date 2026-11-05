# B35 finite qualification

First and only execution: `reports/20261105T183914899205Z/results.json`.
All9 checks passed, with no failures, timeouts, reduced fixtures or retries.
Three checks are default/max/example syntax; three are profile compilation;
three are simulations. Repository-local absolute Icarus/vvp paths and tool
hashes are in the receipt. Each child had a20-second hard timeout, with
process-tree termination and bounded cleanup; the longest recorded child
was6.891 seconds. Only missing time-unit/precision warnings were emitted.

| Capacity/TAG | Packets | Events | Configs | Event holds | Completion holds | Resets | Cycles |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
|64/1|101|44|12|53|505|5|11103|
|257/9|102|44|12|43|510|5|11752|
|4096/32|103|51|12|56|515|5|23390|
|Total|306|139|36|152|1530|15|46245|

Each profile has four live resets (partial capture, first replay read,
held event, held completion) and its initial reset. Each is asserted over
two rising edges. Every live reset is followed by a rejected unconfigured
packet, explicit configuration and a complete fresh attributed-Add packet.
Normal packet bytes total22765; probe/cancelled packet bytes are additional.
The306 packets include160 successes and all nine public rejection statuses.
Unsupported/empty messages consume sequence without creating events; the
large profile contains a mixed packet with supported, unsupported and empty
messages, including empty messages after the final selected event. Capacity
64/257/4096 is actually simulated, including exact-capacity success and
one-byte excess rejection. All profiles test each of the seven selected types.

The direct whole-datagram oracle parses complete bytes, uses ordinary Python
integers and slice/struct fields, and has no hardware FSM or RAM read model.
A literal hand Add anchor checks timestamp/order/quantity/stock/price byte
positions. Additional packets cover field variation, accepted state reuse,
zero/high sequence, stale/future/session rejection and subsequent success,
overflow, heartbeat/end/repeated end, control extra bytes, truncation,
message-count/length lies, every selected type's short/long length, invalid
side/printable, missing KEEP and a good first message followed by a bad later
message. Every emitted event field and every completion field is compared.
Source tags deliberately change on later accepted bytes to check first-byte
ownership. Source gaps and deterministic event/completion stalls are finite.

Seven inputs (DUT, TB, oracle, runner, two file lists and example) were copied
and hashed before model-vector generation or any HDL child. Three fixed ASCII
vectors were saved/hashed before the first child. Current sources and copies,
18 raw stdout/stderr files, three vectors and three ignored VVP images all
match receipt SHA256. No executable source changed after this execution.
`B35_DELIVERY.json` records all seven executed-to-delivered mappings.

Validation scope: functional finite source checks only. The example is syntax
checked, not separately simulated; core profiles cover its production endpoint.
There is no direct simultaneous cfg/payload arbitration probe, indefinitely
held future source offer or every-marker-cycle reset sweep. Those contracts
were statically reviewed, not claimed as direct simulation coverage. No network
traffic capture, official exchange test suite, retransmission engine, host book
recovery, downstream order-ID table or hardware timing was tested. Maturity is
LINT_PASS + UNIT_SIM_PASS + INTEGRATION_CANDIDATE + HW_UNVERIFIED; only the new
composition's listed finite cases qualify, without inherited physical evidence.
