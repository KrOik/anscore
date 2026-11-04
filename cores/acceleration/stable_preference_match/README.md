# Strict proposer-optimal stable matching

`stable_preference_match` computes a stable bijection between N proposers and
N receivers from complete strict preference permutations on both sides. A
blocking pair consists of two agents who both prefer each other over their
returned partners. No such pair exists in a stable result. Among all stable
bijections, each proposer receives its best attainable stable partner; with
strict preferences this proposer-optimal bijection is unique. This optimizes
preference stability, without a maximum-cardinality or minimum-cost objective.

Current qualification is **LINT_PASS / UNIT_SIM_PASS / HW_UNVERIFIED**, bound
to [verification.json](verification.json). All17 first-attempt tool records
passed their expected status, including four named parameter rejections.
The finite matrix was fixed before the first tool; no timeout or retry occurred.

## Fixed-size preference input

One rising-edge clock and synchronous active-high `rst`. There is no CE, CDC,
external memory/bus, dynamic side size or runtime configuration command.
Ordinary `s_valid && s_ready` accepts one32-bit unsigned `s_partner`. Hold
valid and every input field until acceptance or reset. After reset input
opens immediately, one token per clock, in this exact order:

1. All proposer rows, proposer0..N-1, each preferred receiver rank0..N-1.
2. All receiver rows, receiver0..N-1, each preferred proposer rank0..N-1.

Rank0 is best. Every row must be a permutation of0..N-1, with no ties or
omissions. Side, row and rank are implied by position. There are exactly
2*N*N tokens; no KEEP. `s_first` must mark only the first token and `s_last`
only the final token. Markers validate rather than delimit: an early LAST
does not shorten capture, and a missing marker does not extend it. A partial
transaction waits for its remaining tokens or reset. The first accepted
token captures opaque `s_tag`; later tags are ignored, even on marker errors.

Every partner is checked in its full32-bit form before narrowing. Independent
sticky errors are bit0 ID>=N, bit1 a duplicate valid ID in a row, bit2 FIRST
or LAST disagreement. Invalid IDs do not index RAM or update the row seen mask;
valid duplicates still raise their own error. Any error rejects the entire
transaction after all2*N*N tokens drain. No retained-prefix matching exists.

## Result and reset ownership

A valid transaction emits N kept records in ascending proposer order. Each
contains `m_proposer`, assigned `m_receiver`, their respective zero-based
`m_proposer_rank` and `m_receiver_rank`, repeated `m_count=N`, exact repeated
`m_proposals`, first/final markers, first tag and error0. Partners have distinct
IDs and all N are matched. Reversing which side is supplied first changes
which side is optimal; no simultaneous receiver-optimality is promised.

An error emits one masked canonical status: proposer, receiver, both ranks,
count and proposals0; first/last1, captured tag and all sticky flags retained.
Output fields when invalid are unspecified. Valid and all result fields stay
stable under arbitrary `m_ready` stalls. Input stays blocked throughout
initialization, solving and all replay. The next transaction can transfer on
the edge after the final result is consumed; no frame overlap is allowed.

Reset gates public ready/valid low immediately and must span an active edge.
It cancels partial input, pending RAM reads, proposals, matching updates and
held results. Consumers discard an interrupted partial result list. Preference
RAM/read registers are not reset: a valid full permutation capture overwrites
every record before use. Small matching tables initialize serially for N
clocks before the solver reads them. Scalars/output fields reset, with no
cross-reset state-retention claim. Connect a CE-qualified stream through an
explicit adapter.

| Parameter | Default | Legal |
|---|---:|---|
| N | 8 | 1..32, equal complete sides |
| TAG_W | 8 | 1..32 |

Derived localparams are IW=max(1,ceil(log2N)), CW=ceil(log2(N+1)),
PW=ceil(log2(N*N+1)), AW=max(1,ceil(log2(N*N))). Rank/ID fields use IW, count
CW and proposals PW. Each proposer tries a partner at most once, so proposals
are between N and N² and cannot wrap. IDs, ranks, counts and tags are unsigned
integers; there is no numeric scaling or rounding. Illegal public parameters
fail elaboration through `stable_preference_match_invalid_parameters__see_README`.

## Serial FPGA architecture and bounds

Two synchronous RAMs retain proposer preference order and receiver inverse
ranks. Capture checks each row using one reused seen bitmap. The solver
initializes small next-rank/mate/owner tables, serially finds the lowest free
proposer, reads its next partner and that receiver's candidate rank, then
optionally reads the incumbent rank. A receiver accepts a free slot or a
strictly better proposer. Its old proposer becomes free and resumes at the
next untried rank. Receivers only improve. Each rejected pair is impossible
in any stable bijection, proving proposer-optimality at termination. There is
no parallel all-pair comparator network, multiplier, divider, generated table,
vendor primitive, ROM initialization or sibling RTL dependency.

Let P be proposals and S=sum(p+1) over the proposer p of each proposal.
Each lowest-free scan costs p+1 clocks. Exactly N proposals encounter a free
receiver and P-N encounter an incumbent. N initialization clocks plus the
five/six-cycle proposal paths and two replay-read/load clocks therefore give
an exact first-valid delay **S+6*P+2** periods after the accepted final input.
With S<=N*P and P<=N², the conservative bound is N²*(N+6)+2:898default,
38914maximum. Error status is valid immediately after the final input edge
(zero periods). Earliest result transfer is the following edge. Subsequent
records become valid two periods after preceding transfer, for transfer
spacing3 with an always-ready sink. Source gaps and sink stalls prevent an
unconditional wall-clock bound. These are structural schedules, not Fmax.

Preference RAM bits are **2*N*N*IW**,384default/10240maximum. Small indexed
register tables are **N*(CW+2*IW)**,80/512bits. Other declared scalar/read/output
storage is **8+14*IW+2*CW+AW+3*N+TAG_W+PW**,103/239bits. No array has a
parallel reset. The small table accesses may infer registers/muxes; wide
preference RAM mapping and serial search dominate scaling. Resource risk is
LOWdefault/MEDIUMmaximum, a qualitative judgment; no LUT/FF/BRAM/DSP counts,
device fit, timing, power or physical service frequency is measured.

## Offline use and finite verification design

From the package root:

```text
iverilog -g2012 -Wall -tnull -s stable_preference_match -f files.f
iverilog -g2012 -Wall -tnull -s preferences8 -f example/files.f
```

`example/preferences8.sv` forwards every default port; it has instantiation
syntax evidence only. From repository root:

```text
python -B cores/acceleration/stable_preference_match/sim/run.py
```

Only standard-library Python and installed Icarus/vvp are needed. Each tool
child has its own20-second limit; a timeout is terminal for the frozen plan,
with no retry, fixture reduction or limit increase. Ordinary failures and
their old commands/source hashes are retained separately. The current report
binds every nonreport package file. Temporary vectors/executables are removed;
no online download or external software package is required.

The independent verifier directly tests bijection and every possible blocking
pair. It certifies rejection impossibility by induction: if receiver r prefers
winner w to loser l, and every partner w prefers to r is already certified
impossible in any stable matching, then (l,r) is also impossible. At completion
all partners better than each returned mate must be certified impossible.
Together with stability this proves proposer-optimality without reproducing
the RTL's free-agent, owner, queue or scan recurrence. Proposal pairs must be
unique, N initial receiver acceptances distinct, and P=N+certified rejections.
For N<=5 every bijection is additionally enumerated, collecting all stable
solutions and independently choosing each proposer's best stable partner.

The six qualified profiles are (N,TAG_W)1/1,2/3,3/8,5/8,8/16,32/32. N2 covers
every preference profile (16); N3 covers all216 receiver matrices times6 shared
proposer orders (1296). Other families include common/reversed priorities,
cyclic first choices, multiple stable solutions, relabelings, and20 arbitrary
seeded complete matrices at every profile. The maximal N32 domain remains
arbitrary strict permutations and was numerically simulated. Errors
cover full32-bit IDs, duplicates on both sides and independent/combined markers.

The testbench checks all output fields, every first-valid exact
schedule, conservative bound, proposal/rank ownership, actual source stalls,
full-field held outputs and immediate reset cancellations. Fourteen N1 probes
and20 at each other profile cover all reachable states and selected middle
input/init/scan/proposal/replay phases, held valid/error with next input offered.
Unreachable N1 OLD_READ and nontrivial middle/replacement probes are explicitly
excluded. Every reset is followed by a complete common-priority/reverse-receiver
fresh transaction; all N results and the analytic N(N+1)/2 proposal count are
checked. All four illegal parameter checks met their expected rejection.

The complete matrix passed1523main transactions,104590input tokens and5391
output records, with13577proposals and8231inductively certified rejections.
There were1422exhaustive stable-set crosschecks, including29frames with more
than one stable bijection. Each first-valid schedule passed; observed maxima
for the six profiles were9/25/52/147/422/14610periods, within the conservative
bounds. All114immediate reset probes completed full fresh recovery. Main
counts exclude reset/setup/recovery; blocked/held counters in the report are
also main-only. Finite profiles do not prove every legal input/parameter.

All hardware remains HW_UNVERIFIED. No synthesis, PnR, STA, board test or
expanded regression is run. See SOURCES.md for actual pre-RTL implementation
and full-license inspection and capability deduplication.
