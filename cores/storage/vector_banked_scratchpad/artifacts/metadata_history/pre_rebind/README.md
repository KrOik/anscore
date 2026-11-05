# Masked vector banked scratchpad

`vector_banked_scratchpad` owns a complete masked vector of full-word reads
and writes. Different banks execute concurrently. Conflicting lanes replay in
increasing lane order, and one held response completes the whole vector.
It composes an original controller with the unchanged existing
`cip_sync_sp_ram`; this adds a vector memory operation rather than another
AXI router, single-backend arbiter, or external duplicate-read gather.

Current status: **RTL_CANDIDATE / VERIFICATION_NOT_RUN / HW_UNVERIFIED**.
Source, documentation, raw input recipes, independent reference, testbench and
runner are authored only. Preparation, oracle execution, compilation and
simulation require separate specific root approval. No LINT_PASS or
UNIT_SIM_PASS is claimed. No synthesis, PnR, STA or board work is authorized.

## Parameters and ports

| Parameter | Default | Legal values |
|---|---:|---|
| LANES |4|every integer 1..8|
| BANKS |4|1, 2, 4, 8|
| WORDS |64|every integer 1..256, per bank, including nonpowers of two|
| DATA_W |32|8, 16, 24, 32, 40, 48, 56, 64|
| TAG_W |8|every integer 1..32|

Derived ROW_W=max(1,clog2 WORDS), LANE_W=max(1,clog2 LANES), and
COUNT_W=max(1,clog2(LANES+1)) are local, not public overrides. Illegal public
parameters elaborate the named missing module
`vector_banked_scratchpad_invalid_parameters__see_README`. Production logic
and RAM instances exist only in the legal-parameter generate branch.

All ports share one rising-edge `clk`. `rst_n` is **asynchronous active low**,
matching the reused RAM control. Assert reset for at least one rising edge;
release it stably before a rising edge as required by the integrating system.
There is no clock enable or CDC. All transfers use ordinary `valid && ready`
on every rising edge. A source holds valid and every input field until its
handshake or reset. Port zero/lane zero occupies the least significant slice.

| Port | Meaning |
|---|---|
| s_valid/s_ready | Accept and capture one complete vector |
| s_mask[LANES] | Active lane bitmap; zero is a legal empty vector |
| s_write[LANES] | 0 read, 1 full-word store for each active lane |
| s_address[LANES*32] | Complete unsigned **word** indices, 32 bits per lane |
| s_data[LANES*DATA_W] | Store words; ignored for reads and masked lanes |
| s_tag[TAG_W] | Opaque vector tag |
| m_valid/m_ready | Retire the single complete vector response |
| m_status[2] | 0 OK; 1 whole-vector address rejection; 2 unexpected internal RAM error |
| m_mask[LANES] | Original input mask |
| m_error_mask[LANES] | Invalid active addresses for status 1; failing lanes for status 2; otherwise zero |
| m_data[LANES*DATA_W] | Read results in original lane positions; stores/masked/rejected lanes are zero |
| m_tag[TAG_W] | Original vector tag |
| m_accesses[COUNT_W] | Number of accepted scalar bank requests, 0..LANES |
| m_rounds[COUNT_W] | Number of accepted parallel issue rounds, 0..LANES |

Data is opaque unsigned bit content with no arithmetic, sign, fixed point,
endianness conversion, rounding or saturation. A store writes every byte lane.
There are no byte addresses, byte alignment constraints, partial stores, packet
markers, external memory pins, AXI protocol or dynamic configuration bank.

## Preflight, aliases and completion

The legal address set is `[0, BANKS*WORDS)`. Every active lane is compared as
the original unsigned 32-bit word address, widened to 33 bits, **before** any
row cast or RAM request. If ANY active lane is invalid, the ENTIRE vector
returns status 1, the exact invalid-lane bitmap, zero data/accesses/rounds,
and performs no RAM access. Earlier valid stores cannot escape preflight.
Masked lanes ignore address, operation and data, including all-one addresses.
An all-masked vector returns canonical OK, zero data/error/accesses/rounds.

For a valid active address a:

```
bank = a % BANKS
row  = a / BANKS
```

BANKS is a power of two, so RTL uses low-bit selection and a constant shift.
Each round issues the lowest remaining lane for every nonempty bank. The
next round waits until all responses from the current round are captured.
Within a bank, operations are therefore ordered exactly by increasing lane
index. All accesses to the same address map to that bank: a read sees all
earlier lane stores and no later lane stores. Multiple full stores to the
same word leave the highest active writing lane's value. Repeated reads are
NOT deduplicated. Disjoint banks may execute concurrently; no additional
cross-bank order is promised or needed for distinct words.

Only one vector owns the service. No next vector is accepted until the held
response retires, and there is no same-edge response/next-input fallthrough.
`m_valid` and all response fields remain stable through arbitrary backpressure.
Unqualified CE-paused producers need a protocol adapter before this interface.

The reused RAM accepts each request at a rising edge and provides a registered
response afterward. Its store response contains the **old** word, which may be
unknown on the first store. The controller never publishes that value: all
store-result lanes remain zero. An unwritten word is **unspecified**, not zero;
a read of it still returns OK. The caller must initialize words through stores
before relying on their numerical values. No initialization image is required.

The exact unchanged RAM and whole-address preflight make status 2 unreachable
for every legal input/parameter configuration in the intended composition.
The controller nevertheless propagates an observed `rsp_error` as status 2
and zeros its lane, without retry. Status 2 is not externally injectable and
is not claimed as a tested fault-recovery service.

## Reset and visible writes

Reset asynchronously cancels the owned vector, partial read results, all RAM
response slots and any held completion. It immediately suppresses public
ready/valid and internal requests. Every bank receives the SAME reset signal;
there is no old-response drain, epoch protocol or independently reset peer.

**RAM contents are not reset, zeroed or erased.** A store commits when its bank
request is accepted. A subsequent reset does not roll it back, even if the
vector never produced or retired its completion. For a reset between replay
rounds, the accepted prefix remains and unissued stores do not occur. After
reset, new vectors may observe those committed words. The vector is not a
transactional all-or-nothing commit. Atomicity applies specifically to invalid
address preflight, not reset cancellation or internal-fault rollback.

## Architecture and resource budget

One request/response RAM instance per bank is copied unchanged into `rtl/deps`.
Its shared-CE convention is accurately adapted by tying `clk_en=1`, using the
same asynchronous low reset, and consuming every response. No old source is
modified. `SOURCES.md` records the original path and exact raw SHA256.

For n active valid lanes, let R be the largest number mapped to any bank.
Then accesses=n and rounds=R. The first visible response follows input
acceptance by **2R+1** clock periods. Empty/rejected vectors take one period.
With an always-ready response consumer, the next vector may be accepted
2R+3 periods after the prior input (three for empty/rejected). Response stalls
extend service time without changing the first-valid computation. These are
source-derived contractual timings, **not yet measured**.

Logical payload RAM is `BANKS*WORDS*DATA_W`: **8192 bits default**, **131072
bits maximum**. Intended live scalar/response storage, excluding elaboration
loop indices and combinational temporaries, is
`LANES*(36+2*DATA_W)+TAG_W+2*COUNT_W+5+BANKS*(DATA_W+3+LANE_W)`:
**567 default / 1917 maximum** bits, including bank RAM response registers.
These counts are architectural declarations, not synthesis cell measurements.
The controller uses masks, priority selection, counters and comparisons, with
no runtime multiplication/division or DSP requirement. Parallel bank capacity
costs physical port/bank granularity even when logical RAM is small.

Risk is **MEDIUM** at default/maximum: RAM read-first/byte-write mapping and
fragmentation are target dependent; the BANKS-by-LANES selection network and
wide result steering can limit timing. The retained `ram_style="block"`
attribute is not evidence of actual BRAM mapping. No LUT/FF/BRAM/DSP count,
Fmax, power or hardware throughput measurement is claimed.

## Authored finite verification, not yet executed

`RAW_INPUTS.json` freezes six parameter profiles, raw constants, seeds and the
ordered input recipes BEFORE preparation. It is a compact input specification,
not an already-expanded test-result table. The source seal binds it together
with both original input-expansion and independent-reference code. A single
approved preparation child later expands it into explicit immutable `.vec`
files and `oracle_expected.json`; a second specific approval is required for
HDL execution bound to their manifest hash.

The independent oracle uses one flat word dictionary and scalar ascending
lane evaluation. It does not reproduce the RTL state machine or RAM timing.
The testbench also monitors actual bank requests against captured public
addresses/operations, checks first-valid latency and held stability, changes
inactive source fields after acceptance, and never reads or initializes a
hierarchical RAM image. The initial unwritten read has no fabricated expected
data. Initialization is performed through ordinary public vector stores.

Directed cases cover bank parallelism, same-bank replay, read/write aliases,
all masked, full 32-bit invalid addresses, whole-vector rejection, reset
before preflight, reset after exactly the first bank-0 store, cancellation of
a held response, idle reset, preservation of committed data and final complete
memory readback. Ten named parameter rejections and the full-port example are
included. Fixed planning is in `TEST_PLAN.json`: one prepare child, then 25
HDL/log-audit children including six simulations. Nothing has run yet.

`run_tests.py` requires an EXTERNAL root approval enumerating exact argv,
source-seal SHA, stage, attempt and child count. HDL approval must additionally
bind the prepared manifest and explicit absolute compiler/simulator paths.
Every child tree has a 20-second limit. Windows launches suspended children
inside a kill-on-close Job Object before resuming; POSIX uses a new process
group. First failure/timeout stops the stage. Existing outputs are never
overwritten, and the runner has no automatic retry or permissive fallback.
The authored supervisor is itself unexecuted and awaits static review.

From this package directory, ONLY after the matching root approval:

```
python -B run_tests.py --stage prepare --approval D:\anscore\.git\b28-a-prepare-approval.json
python -B run_tests.py --stage hdl --approval D:\anscore\.git\b28-a-hdl-approval.json --iverilog <absolute-exe> --vvp <absolute-exe>
```

The exact planned preparation CHILD is:

```
<the approved absolute Python executable> -B prepare.py --raw RAW_INPUTS.json --out prepared/attempt01
```

`files.f` is the complete offline production closure; `example/files.f` adds
the fixed, full-port `vector_ram4` example. Files are resolved relative to this
package root. Python scripts need only the standard library; approved HDL
checks need local Icarus/`vvp`. No network, generator service, vendor primitive,
include, ROM, external memory or sibling source directory is needed at runtime.
The dependency retains its original module name `cip_sync_sp_ram`: compile it
once per design namespace. When composing source lists, deduplicate this exact
copy against the original existing RAM file rather than compiling both paths.
