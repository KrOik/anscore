# Architecture feasibility

The chosen architecture reuses one serialized synchronous route table and one
checksum atom. A fully parallel prefix CAM would expand128 comparators and a
longest-match priority network; no such packet-rate budget was requested.
A bounded scan gives predictable work proportional to ROUTES with compact
storage. This service admits only one packet/admin owner, so a single shared
checksum and table port suffice without arbitration queues.

Each route row is79 bits: live1+prefix32+length6+value40. Default32 entries use
2528 logical RAM payload bits; maximum128 uses10112. The old table clears one
whole row per clock after reset and reads/checks each row in separate states.
Its synthesis mapping is unmeasured; these are logical capacities, not BRAM
counts or physical area. Two160-bit header registers hold original and working
headers, plus descriptor/FSM metadata. There is no payload/frame RAM, external
storage, multiplier/divider or vendor primitive. Architecture risk LOW at
default / MEDIUM at maximum due scan latency and implementation uncertainty.

One received checksum pass and one regenerated checksum pass each use five
sequential atom transactions, with FINAL asserted after every pair. The prior
folded sum<=65535 plus two16-bit words<=131070 gives maximum196605, safely
below262144. b=0 adds no other words. Verification is enabled only on the final
pair of the first pass. FIRST clears both accumulator and sticky diagnostics
at the start of every pass. The original table/checksum source bytes are reused
through canonical file paths and never rewritten.

Format failure needs no child operation. TTL failure occurs only after a valid
received checksum. A successful header needs one full table scan and ten atom
transactions; there is no claim of one packet per clock or continuous line
rate. Output stalls are unbounded. The owned header isolates all upstream
changes while busy. Config writes cannot race the packet's table snapshot.
Held table replies directly back the public admin response and are retired
only by that same response handshake. Packet replies are independently held.

The checksum helper's native CE is tied1, and low-active asynchronous reset is
explicitly inverted from public rst. The table/wrapper stay on the same clock
with synchronous high-active reset. Public gating prevents apparent transfers
during reset; RAM clear must finish before internal table acceptance. No reset
payload array, asynchronous FIFO or new CDC structure is introduced.

Finite tests must cover full-table replacement, exact deletion with fallback,
/0,/31,/32, host-bit canonicalization, full-width bad lengths, zero next-hop,
header validation precedence, TTL2/255, checksum carry/zero cases, fragments,
maximum ROUTES scan, held config/packet outputs, accepted future offers, reset
inside live work and after held outputs, and unexpected helper-fault recovery.
These source/finite simulation checks cannot establish Fmax, memory mapping,
hold timing, physical packet throughput or board behavior.
