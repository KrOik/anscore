# Whole-span prioritized byte-region permission decisions

`ram_region_guard` retains programmable byte regions and decides whether a
complete requested span has all requested read/write/execute permissions.
The lowest-numbered live rule intersecting **any** requested byte owns the
decision. That rule must contain the whole request; later rules cannot fill
its missing bytes or permissions. Intentional overlapping priority rules and
deny-all overrides are supported. No payload memory access is issued.

`verification.json` is authoritative for `LINT_PASS` and `UNIT_SIM_PASS`,
which require the entire frozen finite matrix. Hardware remains
`HW_UNVERIFIED`. Synthesis, PnR, STA, board work, expanded regression and
inherited matrices are NOT_RUN. [SOURCES.md](SOURCES.md) records actual
whole-library dedup and the complete fixed upstream source/license reads.

## Exact range and permission domain

| Parameter | Default | Legal values |
| --- | ---: | --- |
| `ADDR_W` (A) | 32 | every integer 1..64 |
| `SLOTS` (S) | 16 | every integer 1..64 |
| `TAG_W` (T) | 8 | every integer 1..32 |

`IW=max(1,clog2(S))`, `CW=clog2(S+1)` and `RW=2*A+3` are derived constants.
Unsupported parameters fail elaboration through the named unresolved module
`ram_region_guard_invalid_parameters__see_README`.

`c_base[63:0]` is a full unsigned byte address and `c_bytes[64:0]` is a full
unsigned positive byte count. Validity requires base < 2^A, bytes > 0 and
base+bytes <= 2^A. The sum is computed in 66 unsigned bits before any
narrowing. Zero length is an error. Full-space `(base=0,bytes=2^A)` and final
byte `(base=2^A-1,bytes=1)` are legal, including A=64. Upper input bits never
alias a valid address or length. `c_slot[31:0]` is also checked before
narrowing; valid slots are exactly 0..S-1, including non-power-of-two S.

Rule permissions `c_perm[2:0]` and requested permissions `c_access[2:0]`
use bit0 READ, bit1 WRITE and bit2 EXECUTE. All eight rule permission masks
are legal; zero is a live deny-all rule. A request may require any nonempty
subset, including simultaneous read/write for an RMW operation. Zero request
access is BAD_ACCESS. There is no implication between permissions, implicit
read permission, signed arithmetic, rounding, byte-enable mask or alignment
restriction. Tags are arbitrary T-bit values.

## Commands and serialized ownership

One rising-edge clock, synchronous active-high reset, no CE or CDC. A command
transfers on `c_valid && c_ready`, and its single response on
`m_valid && m_ready`. A source holds valid and every command field until real
acceptance or reset. A real next command may be offered while busy and must
remain held. One accepted command owns the core through the held response.
No following command can intervene, and final response retirement and next
command acceptance never share an edge. An indefinitely stalled consumer can
retain ownership indefinitely.

| Opcode | Operation | Relevant fields |
| ---: | --- | --- |
| 0 | CHECK | base, bytes, requested access |
| 1 | SET | slot, base, bytes, rule permission |
| 2 | DELETE | slot |
| 3 | GET | slot |
| 4 | CLEAR | none |
| 5 | STATUS | none |
| 6..7 | Reserved | BAD_OP |

Every command also carries `c_tag[T-1:0]`. Ignored fields are unrestricted.
For example, GET/DELETE ignore even all-one base/length/permission/access;
CHECK ignores even an invalid slot and the rule permission input. CLEAR and
STATUS ignore all fields except opcode and tag.

SET atomically inserts or replaces its exact slot. It always writes one
complete rule, even when identical to the old one. It never allocates a
different slot or rejects overlap. A replacement succeeds while all slots
are live. A rejected SET leaves the complete prior policy intact. DELETE
clears only the selected live bit and returns NOT_FOUND when already absent.
GET returns that rule without mutation. CLEAR invalidates every rule and
sets count zero without a RAM sweep. STATUS reports the current live count.

Reserved opcode has highest error priority. SET validates slot before range.
CHECK validates range before testing zero requested access. GET/DELETE only
validate slot before testing whether it is live. Other than successful SET,
DELETE and CLEAR, commands never alter policy.

## Whole-span priority decision and response

Represent a valid request by half-open interval `[base,base+bytes)`. Find the
lowest live slot whose rule has a nonempty intersection with that interval.
If no slot intersects, deny as UNMAPPED. If the selected rule does not contain
every requested byte, deny as PARTIAL. Otherwise require every requested
permission to be present in that one rule; absent permissions deny as
PERMISSION. Only complete containment plus permission inclusion allows.

For example, slot0 `[0x1000,0x2000)` permits read, and slot1 covers the whole
address space with read/write. A request `[0x1800,0x2001)` is PARTIAL at
slot0 even for read. A write at `[0x1800,0x1801)` is PERMISSION at slot0.
The broad fallback cannot bypass either result. Adjacent read regions also
cannot authorize one request spanning their boundary. Exact endpoint
adjacency is not intersection. Nested and identical rules remain independent
slots; lower slot priority is decisive, irrespective of length or permission.

| `m_status[3:0]` | Meaning |
| ---: | --- |
| 0 OK | Successful management operation, or allowed CHECK |
| 1 DENY_UNMAPPED | Valid CHECK intersects no live rule |
| 2 DENY_PARTIAL | First intersecting rule does not contain the whole request |
| 3 DENY_PERMISSION | Containing selected rule lacks requested permission(s) |
| 4 BAD_OP | Reserved opcode |
| 5 BAD_SLOT | Relevant full32-bit slot >= S |
| 6 BAD_RANGE | Relevant range has zero length or exceeds A-bit byte space |
| 7 BAD_ACCESS | Valid-range CHECK requests no permissions |
| 8 NOT_FOUND | GET/DELETE selects an inactive slot |

Every valid response echoes `m_op[2:0]` and `m_tag[T-1:0]` and returns the
post-operation live occupancy in `m_count[CW-1:0]`. `m_allow=1` exactly for
an OK CHECK; management success never asserts allow.

`m_found=1` identifies a valid rule descriptor. Successful SET and GET, and
every intersecting CHECK, return the selected `m_slot[31:0]`,
`m_base[A-1:0]`, `m_bytes[A:0]` and `m_perm[2:0]`. PARTIAL and PERMISSION
therefore still identify the exact denying rule. DELETE, CLEAR, STATUS,
UNMAPPED and validation errors have found0 and all descriptor fields zero.
Every field is stable while the response is blocked. There is no separate
KEEP/FIRST/LAST, packet stream, later interrupt or completion token.

Mutations commit before response presentation. A held SET describes an already
written rule; a held DELETE/CLEAR describes already invalidated rules. Reset
immediately gates command-ready, response-valid, allow and found low. Its
active edge cancels work/output and clears the live map, counts and scalar
control/output registers. RAM and its registered read data remain unreset
and unswept; cleared live bits hide old payload. A fresh command can be accepted
on the first edge after reset release. Reset ends canceled source holds.
Descriptor outputs are zero when found is low; other fields are meaningful
only with valid.

This is a serialized permission-decision service. The caller must bind the
checked address, length and intent to the real memory operation, ensure every
relevant access is checked, and coordinate policy updates with in-flight
payload lifetimes. A decision does not reserve an address range or lock policy
after its response retires. Configuration and caller identities are trusted
external responsibilities. No authentication, bus enforcement, architectural
PMP/MPU conformance, privilege modes or isolation proof is claimed.

## RAM, source budgets and clocks

One synchronous-read RAM stores S packed `(baseA,inclusive_lastA,permission3)`
rows: `S*(2*A+3)` bits, **1072 default / 8384 maximum**. An independent S-bit
resettable live bitmap owns all payload reads. READ captures a live row;
CHECK consumes it one clock later. Scanning still spends READ/CHECK clocks
on an inactive slot but performs no physical read there. GET never reads an
inactive slot. WRITE and READ are disjoint, with no collision-mode dependency.

The five states are IDLE, READ, CHECK, WRITE and ACK. A shared index serves
GET/SET and CHECK scan. Response base/last/permission registers also store
pending request/configuration operands while invalid. Inclusive endpoints
are stored only after full input validation; response length is reconstructed
in A+1 bits, preserving a full-space rule.

Clocked scalar declarations, including the packed read register and held
response registers, total `20+S+IW+4*A+2*CW+T` bits: **186 default / 392
maximum**. The components are state3, liveS, indexIW, countCW,
row_q(2A+3), request-access3, descriptor baseA/lastA/permission3/found1,
and response op3/status4/tagT/countCW. There is no parallel all-rule CAM,
multiplier, divider, DSP, vendor primitive or external memory dependency.
Qualitative risk is LOW default / MEDIUM maximum due to wide comparisons and
memory mapping. Physical RAM inference/fit are UNKNOWN. These are declared
source bits, not measured LUT/FF/BRAM, frequency, power or board throughput.

First-valid latency counts complete periods from accepting command edge E
to the edge after which valid is high, independent of ready:

| Path | Latency | RAM reads / writes |
| --- | ---: | --- |
| Valid SET | 1 | 0 / 1 |
| GET of a live slot | 2 | 1 / 0 |
| Valid CHECK, first intersecting slot i | `2*(i+1)` | live slots 0..i / 0 |
| Valid CHECK, no intersection | `2*S` | every live slot / 0 |
| Every other path | 0 | 0 / 0 |

SET writes at E+1. GET reads at E+1 and presents its result at E+2. CHECK
reads slot i at E+2*i+1, if live, and evaluates it at E+2*i+2. It stops on
the first intersection, including denial. Maximum first-valid is **32
default / 128 maximum**. No reads recur while an output is held. The earliest
response transfer is one edge after first-valid; always-ready command
acceptance gap is latency+2. External gaps and blocked responses add directly
to elapsed time and have no finite bound.

## Offline closure and finite qualification

`files.f` contains the sole production RTL. `example/files.f` also contains
the complete default direct wrapper `region_policy16`. No include, package,
generated memory image, sibling RTL, downloaded source or network is required.
The standard-library runner prefers local OSS CAD Suite Icarus/vvp. From this
package directory, the one qualification sequence is:

```text
python -B run_tests.py --seal-source
python -B run_tests.py
```

The delivered plan and source seal are already present. TEST_PLAN.json was
frozen before any RTL implementation, fixing all semantics, profiles, input
and independent-oracle hashes, child names and reset targets. SOURCE_FREEZE.json
separately binds every source before the first HDL child. The runner refuses
any retry or reseal after a receipt exists. An ordinary failure retains complete
original source, plan, seal, receipt, NOT_RUN children and actual input/partial
output before root authorization of a same-stimulus repair. A compiler or
simulator timeout is terminal: no retry, smaller fixture or larger limit.
Every child has a fixed 20-second timeout. There is no post-PASS source refresh.

Exactly 18 children are fixed: version, combined core/default-wrapper syntax,
five compile/simulation pairs and six named invalid parameter rejections.
A/S/T profiles are 1/1/1, 8/3/3, 17/5/8, 32/16/8 and 64/64/32.
Rejections cover A=0/65, S=0/65 and T=0/33. Main inputs have **9984 commands
and 9984 single responses**. The primary oracle uses a plain dictionary of
unbounded half-open integer intervals and permission sets. A<=8 additionally
expands actual byte sets for an independent intersection/containment check.
Neither oracle reproduces hardware read phases or controller state.

Every output bit, count, live bitmap and complete owned RAM image is checked
after every main response. Exact first-valid and owned read/write counts are
checked for every command. The TB checks popcount/count and RAM bounds at every
nonreset edge, and the exact registered value of every live synchronous read.
Fixtures include all64 base bits, all65 length bits, all32 slot bits, full-space
and last-byte rules, every rule/request permission pair, priority fallback,
adjacency, nested/identical overlaps, partial denial, active replacement/error
preservation, full occupancy, ignored invalid fields, all729 singleton
three-command streams and 600 deterministic mixed commands per profile.

The actual next frozen command is held through its real handshake. Every main
response is held for at least three edges. Each profile has 22 immediate
observed-boundary reset targets: idle; pending SET; GET read/compare; first and
later CHECK read/compare; held new/replacement SET, GET, allow, partial,
permission, unmapped, DELETE, CLEAR, bad access/range/slot/op and STATUS.
Later CHECK aliases first at S=1. Held targets also preoffer an actual future
CLEAR. Reset is asserted at that observed falling-edge boundary before any
extra work edge. Each cancellation runs a complete 20-command fresh recovery:
empty observation/denial, full-space fallback SET/GET/CHECK, short override,
partial and permission denials, replacement deny-all, deletion/fallback,
new full-space allow at the last byte, clear and fresh missing/empty checks.
All outputs retire and all owned RAM is checked; each recovery ends empty.
There are 110 planned resets and 2200 fresh commands. Actual counts and hashes
are retained in the receipt. These finite cases are not proof of every policy
history, scheduling interleaving or system integration.
