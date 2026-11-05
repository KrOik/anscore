# RAM ordered dictionary

RTL_CANDIDATE / HW_UNVERIFIED. All preparation, oracle, lint, compile, simulation,
synthesis, PnR, STA and board execution statuses are NOT_RUN. This is a source-only
authoring package awaiting independent review and separate root execution gates.

This bounded persistent dictionary accepts unordered runtime updates to unique
unsigned keys. It provides exact GET, replacement/insertion PUT, DELETE,
SEEK_GE (the first stored key at least the query), inclusive ordered RANGE, and
CLEAR. No host sorting, compressed bucket IDs, frame boundary or generated data
table is required. See SOURCES.md for semantic dedup and provenance.

## Parameters and numerical contract

CAPACITY is 1..32; K_W and V_W are 1..32. Defaults are 32/32/32.
COUNT_W must equal max(1,ceil(log2(CAPACITY+1))); its default is derived.
Invalid parameters instantiate the named missing module
ram_ordered_dictionary_invalid_parameters__see_README.
All keys and values are exact unsigned integers. Every bit pattern, including
zero, high-bit-only and all ones, is legal; no sentinel or signed interpretation
is used. There is no rounding, fixed-point scaling, overflow arithmetic on values
or numerical tolerance. Key equality/order is exact.

## Full port contract

| Port | Type | Contract |
|---|---|---|
| clk | input | Rising-edge single clock |
| rst_n | input | Active-low asynchronous control reset; match shared RAM polarity |
| s_valid / s_ready | input / output | Ordinary ready/valid command, no public CE |
| s_op | input 3 bits | 0 GET,1 PUT,2 DELETE,3 SEEK_GE,4 RANGE,5 CLEAR;6/7 BAD_OP |
| s_key | input K_W bits | Lookup/update key or inclusive RANGE low endpoint |
| s_value | input V_W bits | PUT value; ignored for every other command |
| s_hi | input K_W bits | Inclusive RANGE high endpoint; otherwise ignored |
| m_valid / m_ready | output / input | Ordinary ready/valid response stream |
| m_kind | output 2 bits | 0 RESULT,1 RANGE ROW,2 RANGE END |
| m_status | output 3 bits | 0 OK,1 NOT_FOUND,2 FULL,3 BAD_RANGE,4 BAD_OP |
| m_found | output bit | Existing key on entry for GET/PUT/DELETE; found key for SEEK;1 for ROW;0 for END/CLEAR/errors |
| m_key / m_value | output K_W / V_W bits | Successful key/value, otherwise zero |
| m_count | output COUNT_W bits | Logical occupancy after this command's mutation; unchanged through RANGE |

GET success returns the stored binding. PUT success returns the input binding;
m_found distinguishes replacement from insertion. Replacing while full is legal.
New-key PUT while full rejects before shifting, with FULL, zero key/value/found,
and unchanged count. DELETE success returns the removed key and old value;
missing GET/DELETE/SEEK returns NOT_FOUND without mutation.
CLEAR returns OK/zero key/value/found/count and invalidates logical occupancy
without bulk-clearing RAM. Invalid opcode returns one RESULT/BAD_OP.

A valid RANGE emits zero or more ascending ROW/OK/found=1 bindings followed by
exactly one END/OK/zero key/value/found. lo>hi emits only END/BAD_RANGE.
Equal endpoints are legal. Empty ranges still emit END. Count is unchanged.
ROW retirement does not release the store; the END handshake does.

A producer holds every command field stable while valid and not ready. A consumer
may stall any response, including END, indefinitely; every response bit remains
stable while valid and not ready. One command owns the store from acceptance
through its single RESULT or RANGE END retirement. Ready is low during ownership.
The next command cannot be accepted on that retirement edge; it can be accepted
on the following edge. Payload fields are unspecified when their valid is low.

Reset assertion immediately masks s_ready/m_valid, empties count and cancels
the command, RAM-response control and held response. RAM data is never reset.
A reset during shifting discards all logical contents, including earlier completed
commands. Fresh commands start from empty and cannot read stale rows. A receiver
discards any RANGE prefix without END across reset. Reset deassertion must meet
clock-domain recovery/removal requirements; this module is not a reset synchronizer.

## Architecture and reuse

Sorted packed rows reside in one unchanged cip_sync_sp_ram. One extended unsigned
subtract supplies the shared key comparison (<,==,>) for bound search, exact match,
range validation and upper-end termination. A binary lower-bound search is followed
by at most one bound-row read. Insertion shifts rows high-to-low; deletion shifts
low-to-high. One temporary row and the command value register suffice; DELETE's
dead input-value register saves the removed value while shifting. RANGE reads
successive rows and blocks mutations until END is accepted.

The RAM has one request and one response slot, a synchronous read, byte writes
and read-first write responses. This core ties clk_en high, uses full-byte strobes,
ignores write-response payloads and waits for every response before reuse. Packed
row width is 8*ceil((K_W+V_W)/8); padding is zero and never compared. There is no
CAM, pointer tree, vendor primitive, external memory or multiplier.
COST.md gives storage/control budgets, cycle reasoning and tradeoffs.

Both files.f and example/files.f use the PACKAGE DIRECTORY as path base, explicitly
in their comments. From this package directory, each source line resolves directly.
Do not reinterpret example/files.f relative to example/. The all-port
example/ordered_dictionary32.sv fixes default widths and preserves every handshake.

## Fixed finite verification source

RAW_INPUTS.json contains exactly three named profiles:
p0=(1,1,1), p1=(5,9,7), p2=(32,32,32). Programs are literal operation sequences,
not a Cartesian input-domain enumeration. They cover empty/full, replacement at
full, rejected insert at full, missing deletion, zero/high-bit/all-ones keys,
middle/endpoint shifts, lower bounds, invalid/exact/empty/full range, CLEAR/refill
and opcode errors. Each main program has exactly two fixed stall modes,0 and1.

Twenty-seven named reset jobs (7/10/10) interrupt binary-search RAM wait, bound read,
final PUT write, held RESULT, held RANGE ROW/END and a real next command offered
behind the owner. p1/p2 additionally interrupt insertion read/write shifts and
deletion write shifts. Every reset holds a command offer for three reset-asserted
edges; next_offer retains the actual future PUT across reset and confirms its
first later handshake. Each job runs a fixed fresh program proving empty state
and subsequent writes, query, range and delete. No seeds or expanded runs exist.

The independent oracle uses a Python dictionary plus sorted keys; it does not
duplicate RTL binary search or shifting. prepare.py generates only these fixed
programs after exact AUTHOR_INPUTS approval, writes exclusive prepared output and
records all fixture hashes/counts. It has not run. The later stored-hash child
does not re-evaluate the oracle.

TEST_PLAN.json fixes 22 children:1 stored-hash check,2 lint/example compiles,
3 TB compiles,6 main simulations,3 reset simulations,7 named invalid-parameter
rejects. The last reject tests an inconsistent COUNT_W. No HDL child prepares or
reruns the oracle. No pass is presently claimed.

run_tests.py has separate --prepare, --seal and --execute modes. Root approval
JSON lives outside this package. Preparation requires schema b29-a-prepare-once-v1,
exact author and preparation-plan hashes, one invocation,20 seconds and no retry.
After independently reviewed preparation, --seal freezes all source/fixture bytes.
HDL requires schema b29-a-fixed-hdl-once-v1, exact author/seal/test-plan hashes and
the exact22 child descriptions, one invocation,20 seconds and no retry.
Never run these entrypoints without their specific root gate.

Windows children are created suspended, assigned to a kill-on-close Job before
resume, and run with a hard20-second process deadline plus a bounded3-second
failure drain. Each raw stdout/stderr is saved before validation. First failure
stops later slots as NOT_RUN and archives partial sources/raw/VVP; no retry or
automatic repair is present. Copies/source/seal/approval/tool bytes and generated
artifact exact sets/hashes are checked around every child. Successful VVP cleanup,
if ever approved, is root-owned and requires an explicit hash receipt.

TOOLCHAIN.json statically seals Python, Icarus/vvp, ivl/ivlpp, null/vvp target DLLs,
two backend configurations, six VPI modules and all local PE imports (20 PE files,
8 DLLs). Exact suite/bin then suite/lib prefix PATH; the inherited suffix is
retained and its/effective hashes recorded. No missing-DLL recovery or toolchain
retry is allowed. Actual dynamic load tracing and execution are NOT_RUN.
