# Persistent mass index with exact range sums and weighted selection

`ram_fenwick_index` stores an unsigned mass at every fixed bucket index.
SET replaces one mass, RANGE sums an inclusive index interval, SELECT locates
one zero-based mass rank, and CLEAR empties the entire index. It computes its
own cumulative state in local synchronous RAM; callers do not supply a tree,
prefix sums, sorted samples or a generated image. This supports persistent
event/quota distributions and weighted routing/control decisions. It does
not perform packet transport, payload allocation or physical memory access.

## Domain and command contract

| Parameter | Default | Legal domain |
|---|---:|---|
| BUCKETS | 64 | Every integer 1..256, including non-powers of two |
| COUNT_W | 16 | 1..32 |
| TAG_W | 8 | 1..32 |

N=BUCKETS. Local widths are IW=max(1,clog2 N), NW=max(1,clog2(N+1)) and
SW=COUNT_W+clog2 N (clog2 1=0). They are derived, not public overrides.
Each bucket mass is0..2^COUNT_W-1. All sums/ranks are unsigned SW-bit exact
integers, without fixed point, wrap, rounding or saturation. Since
N*(2^COUNT_W-1)<2^SW, every legal distribution's full sum fits. Illegal public
parameters fail elaboration through
`ram_fenwick_index_invalid_parameters__see_README`.

All ports use one rising-edge clk; synchronous active-high rst has priority.
There is no CE, CDC, external memory or runtime configuration bank. Commands
transfer on `c_valid && c_ready`; hold all source fields/valid while blocked.
One command owns the index through its held response, and the next command
waits until response retirement. Responses transfer on `r_valid && r_ready`;
every field/valid is stable during arbitrary backpressure. There is no frame
or LAST signal and no next-command/response same-edge fallthrough.

| c_op | Operation | Relevant fields |
|---|---|---|
| 0 | SET | unsigned32 c_lo bucket; c_value new mass |
| 1 | RANGE | unsigned32 c_lo/c_hi inclusive bounds |
| 2 | SELECT | SW-bit c_rank, zero-based in current total mass |
| 3 | CLEAR | all data/index/rank fields ignored |

Every operation encoding is defined. SET ignores c_hi/c_rank. RANGE ignores
c_value/c_rank. SELECT ignores c_lo/c_hi/c_value. c_tag is opaque and echoed
unchanged; ignored fields can contain all-one bits without rejection.
SET requires c_lo<N. RANGE requires c_lo<=c_hi<N, so empty/reversed intervals
are rejected. Both32-bit indices are validated before narrowing. SELECT
requires rank<total; an empty index rejects every rank, including zero.

| Response | Meaning |
|---|---|
| r_op/r_tag | Captured operation and tag on every response |
| r_status0 | OK |
| r_status1 | Bad SET index or RANGE geometry; no mutation |
| r_status2 | SELECT rank>=total; no mutation |
| r_status3 | Not generated |
| r_index | SET bucket or selected bucket on OK; zero for RANGE/CLEAR/errors |
| r_sum | SET's **old** mass; RANGE sum; SELECT mass strictly before selected bucket; zero for CLEAR/errors |
| r_total | Exact post-command total; unchanged on queries/errors |

For successful SELECT at index j, prefix=sum(mass[0:j]) satisfies
`prefix<=rank<prefix+mass[j]`. Thus a zero-mass bucket is never selected.
The least j with cumulative mass greater than rank is unique, even across
long zero gaps. Rank0 and total-1 select the first and last nonempty buckets.
SET can increase, decrease, zero or retain any mass; it returns the previous
value zero-extended to SW bits. No overflow/admission limit is hidden behind
SET because an absolute COUNT_W-bit value always preserves the proven domain.
CLEAR returns zero index/sum/total and retains its op/tag.

Mutations complete **before response presentation**. SET writes the leaf and
total, then repairs every aggregate ancestor before valid is raised. Those
partial private writes cannot be observed by another command. CLEAR sets the
total to zero at acceptance and writes all rows before its response. ACK
retires an already completed mutation; no rollback or response-ACK commit is
provided. Output payload outside valid is not a transaction snapshot.

## Reset, storage and finite scheduling

Asserting rst gates public ready/valid low immediately. An active reset edge
cancels any command, partial repair/query or held normal/error response and
clears public response fields/op/total. On the next N clocks after release,
one row in **both** banks is zeroed per cycle; c_ready remains low until the
sweep completes. Canceled commands return no completion. This discards every
previous mass; callers replay decisions as needed. Unreset read/intermediate
registers are overwritten by current-command states before consumption.
No canceled RAM content survives the sweep into a new command.

A leaf RAM stores N*COUNT_W bits. A Fenwick RAM stores N*SW bits: its one-based
entry i covers the interval `[i-lowbit(i),i)` of zero-based leaves. SET reads
the old leaf, computes the absolute delta and walks i=index+1,
i+=lowbit(i), repairing one aggregate per three read/compute/write clocks.
The extended next-index addition detects termination before narrowing, also
at the power-of-two maximum. A decrease cannot underflow any covering interval,
and all increased aggregates remain below the full legal total bound.

RANGE separately walks descending prefix endpoints hi+1 and lo, then subtracts
their exact masses. SELECT binary-lifts from the greatest power of two<=N,
reading a candidate aggregate only when its one-based index<=N. It advances
past a prefix only when that mass<=rank. Candidate mass comparison has one
extra bit; final rank validity ensures the returned index<N. This schedule
handles arbitrary non-power-of-two N without padding buckets or reading
out-of-range RAM. There is no linear all-bucket query scan in the RTL.

Each bank has one synchronous read and one synchronous write port. Read and
mutation phases are disjoint; no read-during-write collision mode is assumed.
CLEAR uses ordinary row writes rather than reset on every stored bit. No
multiplier, divider, DSP primitive, external storage, ROM generator, runtime
recursion, scratch register array or sibling dependency is required.

Logical arrays total `N*(COUNT_W+SW)` = **2,432** default / **18,432** maximum
bits. Scalar/read/output declarations total
`11+3*COUNT_W+8*SW+3*IW+4*NW+TAG_W` = **289 / 519** bits.
Combinational next-index/mass temporaries are not counted as stored bits.
These are declaration counts, not inferred or mapped RAM/LUT/FF quantities.
Qualitative resource/timing risk is LOW default / MEDIUM maximum from memory
mapping, mass addition/comparison and index selection. Frequency, device fit,
power and physical resources remain unmeasured.

If a SET changes m aggregate ancestors, response valid is presented
`2+3*m` periods after acceptance; an unchanged SET takes2. RANGE takes
`3*(popcount(hi+1)+popcount(lo))+1`; SELECT takes at most `3*NW+2`.
CLEAR takes N periods and rejected geometry/rank produces valid by the
accepting edge. The TB checks a conservative sampled first-valid bound
`max(N+1,6*NW+8)`: CLEAR presents after N periods and a rising-edge monitor
observes that valid on the next edge. Output stalls add arbitrary occupancy and there is no
unconditional whole-workload completion deadline. These are RTL cycle
schedules, not measured hardware throughput.

## Offline closure and fixed finite evidence

files.f includes only rtl/ram_fenwick_index.sv. example/files.f adds the
default mass_index64 wrapper and includes its whole source closure. It forwards
every command/result signal and is an INTEGRATION_CANDIDATE by syntax evidence.
No network, generated table, include or hidden external module is needed.
The original local contribution is Apache-2.0 (local LICENSE and root NOTICE).
[SOURCES.md](SOURCES.md) records the actual source/full-license preflight and
semantic duplicate check before RTL authoring.

Run `python -B run_tests.py` from this package or the corresponding path from
the repository root. The standard-library runner uses installed Icarus/vvp,
preferring repository OSS CAD Suite. Every child has a20-second ceiling.
A timeout records TIMEOUT_NOT_RUN and stops this batch; subsequent invocations
refuse to retry a previous timeout. There is no smaller fixture, increased
timeout or automatic retry. Ordinary failures retain exact tool records and
source hashes in history, without being qualified as passing results.
Prior overall evidence is replaced with NOT_RUN before checking; PASS is
published only after the complete frozen matrix, encoding and hash-stability
checks finish. Every source/document, vector, flat-list history and actual
snapshot is SHA-bound. Text is strict UTF-8 without BOM and LF only.

TEST_PLAN.json is frozen before the first compiler/simulator invocation.
N/W/T profiles are1/1/1,3/5/3,16/8/8,64/16/8 and256/32/32;18 children include
version/lint, five compile/sim pairs and six named illegal-parameter settings.
Every bucket is filled to its maximum and tested at both boundary ranks,
single/prefix ranges, exact maximum total, zero holes and decreases. High32-bit
invalid indices, ignored-field extrema and320 seeded mixed commands/profile
are included. The minimum profile additionally covers all729 three-command
sequences from nine choices, each preceded by CLEAR. These are finite tests,
not a full proof over legal parameter combinations or input histories.

The independent functional oracle stores a flat Python integer list, uses
ordinary slice sums and linearly scans counts to select a rank. It does not
reproduce the RTL's tree update, prefix walk or binary lifting. Every public
response is checked, followed by all leaf values and every aggregate's direct
interval sum, catching stale or duplicate updates without relying on later
queries. Every main response is held at least four clocks; complete source and
response stability and real blocked-source/consumer cycles are counted.

Twenty immediate observed-phase reset probes/profile cover all16 FSM states,
held success/error, a live-bank interior clear and the second RANGE prefix
side. N1 omits that unreachable second-side case, yielding19 probes there.
No extra active edge precedes cancellation after observation. Every reset
runs a complete checked fresh recovery: both banks zero, point SET/query,
last-bucket mass, range/rank after a zero gap, decrease, CLEAR and empty-rank
rejection. Minimum N1 exercises its one bucket with corresponding results.
Recovery/setup commands are additional to main responses/physical checks.
Cycle, stall and read/write counters include **all non-reset probe, setup,
recovery and main activity**, rather than only main commands.

Actual totals and status are in verification.json. On complete success the
finite maturity is LINT_PASS / UNIT_SIM_PASS / HW_UNVERIFIED; this is not
hardware qualification. No synthesis, PnR, STA, hardware or expanded
regression is authorized or run.

The complete corrected frozen matrix passed18 children, including six named
parameter rejections, with zero positive stderr and no timeout. Main-command
counts by N are3267/366/463/823/2263: **7,182** responses with **643,773** leaf
checks and the same number of aggregate-interval checks. The99 immediate
reset probes ran981 additional fully checked recovery/setup commands.
All-non-reset counters are155541 clocks,117926 source-blocked and35116 held
response clocks. Main oracle coverage includes915 increases,477 decreases,
673 unchanged SETs,529 selections after zero gaps,419 last-rank selections,
827 bad geometries and585 bad ranks. The conditional SELECT candidate>N skip
counter is zero in these fixed profiles; that branch has static scheduling
review rather than a claimed simulation witness. Legal parameter coverage is
the exact matrix above, not every N.

One initial ordinary failure is preserved separately in
history/failure_001.json, with original source hashes and exact stdout.
history/bound_alignment_note.json explains the corrected sampled CLEAR bound
and records old/new TB/runner hashes. The RTL, oracle, fixtures, TEST_PLAN and
20-second tool limit were unchanged. The entire original matrix then ran
successfully; verification.json contains only that completed qualified run.
