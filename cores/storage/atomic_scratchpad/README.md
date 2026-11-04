# Atomic word scratchpad

`atomic_scratchpad` provides word storage with indivisible read/modify/write
commands. Each command returns the previous word, a write-performed flag,
status and caller tag. A scheduler can arbitrate several clients into this
single command port to implement shared counters, bitmaps, min/max reductions
or compare-and-swap ownership. Every memory access goes through this port, so
another command cannot intervene between a read and its matching write.

## Parameters and interface

| Parameter | Legal values | Default |
| --- | --- | --- |
| `DATA_W` | 2..64 | 32 |
| `DEPTH` | 1..4096, including non-powers of two | 256 |
| `TAG_W` | 1..32 | 8 |

The word index width is `max(1, ceil(log2(DEPTH)))`. `s_address` is a **word
index**, not a byte address. There are no byte masks, alignment rules or partial
word operations. Indices `0..DEPTH-1` are valid; unused encodings are rejected.
Illegal parameters fail elaboration with the named parameter-error module.

All ports use the rising edge of one `clk`. `rst` is synchronous active high
and has priority over transfers. Asserting it gates `s_ready` and `m_valid` low.
The reset edge cancels any pending operation/response and restarts a sequential
zeroing sweep. On the first DEPTH rising edges with reset low, addresses
0 through DEPTH-1 are written to zero. `initializing` stays high throughout
reset and the sweep; requests are blocked until it completes. Reasserting
reset restarts the sweep. A completed initialization guarantees every word is
zero, including words modified before the reset. Reset does not promise a
response for a canceled command.

There is no clock-enable signal. Every `s_valid && s_ready` edge accepts one
complete command (`s_op`, `s_address`, `s_operand`, `s_compare`, `s_tag`). The
source holds those fields and VALID stable while blocked. All command fields
are captured at acceptance; later input changes cannot alter an operation.
The buffer holds one command and one associated response and accepts the next
command after the preceding response is acknowledged.

Every `m_valid && m_ready` edge consumes a response. `m_old`, `m_wrote`,
`m_status`, `m_tag` and VALID remain stable while `m_valid && !m_ready`.
Response fields are meaningful only with VALID. `m_tag` echoes the accepted
caller tag. One response represents the complete transaction, so there is no
LAST/frame marker. Parameters are the only configuration and take effect at
elaboration. CE-qualified streams require an interface adapter before connection.

## Operations and error semantics

Let `old` be the current word and `arg` be `s_operand`. Every operation returns
`old` in `m_old` when its command is valid.

| `s_op` | Operation | New memory value |
| --- | --- | --- |
| 0 | Read | unchanged, `m_wrote=0` |
| 1 | Exchange | `arg` |
| 2 | Fetch-add | `(old + arg) mod 2**DATA_W` |
| 3 | Fetch-XOR | `old XOR arg` |
| 4 | Fetch-AND | `old AND arg` |
| 5 | Fetch-OR | `old OR arg` |
| 6 | Signed minimum | `min(old,arg)` interpreted as signed two's complement |
| 7 | Signed maximum | `max(old,arg)` interpreted as signed two's complement |
| 8 | Unsigned minimum | `min(old,arg)` interpreted as unsigned |
| 9 | Unsigned maximum | `max(old,arg)` interpreted as unsigned |
| 10 | Compare-and-swap | `arg` if `old == s_compare`, otherwise unchanged |

No fixed-point scale is imposed. Arithmetic add wraps at DATA_W; it does not
saturate or produce an arithmetic-overflow error. `s_compare` is used only for
opcode 10. `m_wrote=1` for opcodes 1..9 even if the stored bits remain identical;
for compare-and-swap it is one exactly when the comparison succeeds. A failed
comparison is a successful command (`m_status=0`, `m_wrote=0`) returning the
observed old value.

`m_status=0` means a valid operation, 1 means an invalid encoded word index,
and 2 means an undefined opcode (11..15). Undefined opcode takes priority if
both are invalid. Rejected commands do not access memory and respond with
`m_old=0`, `m_wrote=0` and the original tag. There is no external memory-error
interface. All memory is internal and there are no CDC or vendor primitive
dependencies.

A valid command accepted on edge E reads memory on E+1, computes on E+2, and
commits its write (if any) on E+3. Output VALID becomes visible after E+3, so
the earliest response transfer is E+4. Read and failed-CAS commands use the
same schedule. With response-ready held high, successive valid command
acceptances are at least five clocks apart. Rejected commands expose a
registered response immediately after E and can transfer on E+1. A stalled
consumer can delay the next command indefinitely. A reset during a held
response cancels it and clears the entire bank before subsequent use; earlier
writes do not survive the new initialization.

## Architecture and offline use

`files.f` lists the complete production source. There are no include files,
initialization images, ROM tables, generators or external libraries. From this
package directory:

```text
iverilog -g2012 -Wall -tnull -s atomic_scratchpad -f files.f
```

`examples/atomic_counter_bank.sv` instantiates 256 modulo-32-bit fetch-add
counters and preserves caller IDs through the response. The parent supplies
client arbitration and observes standard ready/valid. Its initialization and
response backpressure follow the same contract as the core.

Memory has one explicit synchronous write port shared by initialization and
commit, and one synchronous read port. Read and write states are mutually
exclusive, so no read-during-write collision behavior is required. The array
is initialized by ordinary writes rather than a reset on every payload bit.
One adder, bitwise operations and one sign-biased ordering comparator implement
the command set; no multiplier or DSP is needed. The RAM-read, arithmetic and
write are separate scheduled phases. The expected arithmetic path is a word
adder or min/max comparator plus selection, not an unrolled transaction loop.

Default qualitative resource risk is **LOW** with 8,192 logical memory bits and
a small serialized datapath. Supported maximum storage is 262,144 bits at
64x4096; resource risk there is **HIGH** until actual target mapping is known,
especially if the memory is mapped into registers instead of block RAM.
Memory size grows linearly with DEPTH and DATA_W. Actual RAM inference,
granularity, target fit, frequency, power and physical resources are unmeasured.
The initialization and service cycle counts above describe RTL scheduling.

Run the bounded checks from the repository root:

```text
python -B cores/storage/atomic_scratchpad/check.py
```

The runner prefers the local repository OSS CAD Suite and supports `IVERILOG`
and `VVP` overrides. Each subprocess has a 20-second timeout. Simulator images
and generated command vectors live in a task-specific `TemporaryDirectory`
and are automatically removed. `verification.json` binds the actual commands,
results and vector/source SHA-256 values. All text is LF with local Git
attributes, preserving the source hashes through commit.

An independent Python integer/list model updates memory according to operations,
without modeling RTL states. Deterministic coverage includes full initialization
and word isolation, all 11 operations, signed/unsigned extrema, modular addition,
successful and failed CAS, write-followed-by-read, undefined opcodes, invalid
indices, input mutation after capture, response stalls/field stability, partial
initialization restart and five cancellation time points followed by reuse.
DATA_W/DEPTH/TAG_W profiles 2/1/1, 8/3/4, 32/16/8 and 64/257/32 execute
798, 874, 995 and 1,812 oracle commands respectively. Maximum parameters have
syntax/elaboration coverage only; four illegal configurations are rejected.

Maturity: **LINT_PASS** (Icarus syntax/elaboration), **UNIT_SIM_PASS**, and
**HW_UNVERIFIED**. The counter connection remains an **INTEGRATION_CANDIDATE**.
Synthesis, PnR, STA, full regression and board tests were NOT_RUN. The finite
tests do not establish hardware timing or exhaustive correctness. Source and
license review are recorded in `SOURCES.md`.
