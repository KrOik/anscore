# Exact strict increasing subsequence and witness

This service accepts raw signed integer samples and returns the exact length
of a longest **strictly** increasing subsequence (LIS), together with one
optimal subsequence in forward order and its original sample indices. Equal
values cannot extend the subsequence. Samples may be unordered and repeated;
no host sorting, rank preprocessing or index calculation is required.

## Interface and ownership

One rising-edge clock, synchronous active-high `rst`, ordinary ready/valid;
there is no CE. Transfer is `valid && ready` at the rising edge. Reset gates
ready/valid low immediately; an asserted reset edge cancels all work and clears
public output registers. The next transaction starts fresh without clearing
RAM: every later read is bounded by newly initialized length/count state.
Legacy CE-qualified streams require an explicit adapter.

- Parameters: `VALUE_W=16` (1..32), `MAX_SAMPLES=64` (1..256), `TAG_W=8`
  (1..32). IW=max(1,ceil(log2 MAX_SAMPLES)), CW=ceil(log2(MAX_SAMPLES+1)).
  Derived local parameters cannot be overridden. Illegal settings fail
  elaboration through `longest_increasing_subsequence_invalid_parameters__see_README`.
- `s_value` is signed two's-complement VALUE_W, exact integer; no fixed point,
  truncation, rounding or saturation. A kept token appends one sample; its
  original index is its **kept-sample ordinal**, excluding masked tokens.
- `s_first` must be 1 exactly on the first accepted token of each frame,
  including a masked token. Every other accepted token must have first=0.
  `s_last` closes the frame and can appear on a masked token. Masked values
  are ignored. A single masked first/last token represents an empty sequence.
- The first accepted token owns tag, including a masked first token. All
  later tags are ignored. An absent last waits indefinitely for input/reset;
  there is no timeout or maximum masked-token count.
- All source fields must remain stable while valid and blocked. One frame
  is owned through its final output transfer. New input cannot transfer on
  that same edge; no inter-frame overlap, prefetch or configuration updates.
- A nonempty valid frame emits L kept records, in increasing rank 0..L-1.
  `m_index` and `m_value` select an original sample. Indices and signed values
  both strictly increase. `m_length=L`, `m_count` is the kept input count, and
  the first tag repeat on every record. First/last mark ranks 0/L-1. L is
  optimal, but **no canonical choice among tied optimal witnesses is promised**.
- A valid empty frame emits one masked first/last record, errors=0, all
  numerical fields zero and first tag. Any invalid frame emits the same
  canonical masked record with sticky errors: bit0 FIRST disagreement,
  bit1 more than MAX_SAMPLES kept samples. Both bits can coexist. After an
  error the entire frame still drains through last; no prefix is published.
  Kept tokens after capacity do not write RAM. LAST itself is the delimiter,
  so there is no independent expected length against which to reject it.
- Output valid and every payload field stay stable under backpressure. An
  empty/error held record has the same ownership/reset behavior as a witness.

## Architecture and structural budget

For each kept value x, serial binary search finds the first minimum-tail value
>=x. Its position p is the longest strict subsequence ending at x minus one.
The tail at p is replaced; a predecessor points to the previous tail at p-1.
When p equals the current length, the optimum grows. Predecessors always point
to earlier kept indices, so later tail replacement cannot corrupt a recorded
chain. At frame end the final maximum tail is traced backwards into a witness
RAM; forward replay then produces ordered records. Signed comparison is
explicit. The upper search bound can equal capacity but is never dereferenced.

Three local synchronous memories each contain MAX_SAMPLES*(VALUE_W+IW) bits:
tail value/index, historical value/predecessor, and witness value/index. Total
raw arrays: **4224 default /30720 maximum bits**. Read and consume states are
distinct; reads and writes of each RAM occur in different states and do not
assume read-during-write behavior. No array-wide reset, parallel search tree,
multiplier/divider, external RAM, ROM file, vendor primitive or CDC is used.
Actual mapping, LUT/FF/BRAM use, frequency and power remain unmeasured.

The explicitly declared scalar storage is
`4+3*(VALUE_W+IW)+VALUE_W+4*IW+7*CW+2+TAG_W+2 + VALUE_W+2*IW+2*CW+3+TAG_W+2`
bits (FSM, RAM output registers, current/search/trace/frame state and public
outputs); **226 default /390 maximum bits**. This is an RTL register-bit count,
not a synthesis result. Resource risk LOW default, MEDIUM maximum because RAM
inference and physical allocation are unverified.

If binary search takes k comparisons, processing one kept input through its
write takes 2k+2 additional cycles for p=0, or 2k+3 for p>0. k is at most
ceil(log2(MAX_SAMPLES+1)); masked/error drain is II1. From the final input,
finish/trace setup costs 2 cycles, traceback 2L cycles, and each output uses
read/load/held-transfer phases. A conservative always-ready bound to the final
transfer is `2*ceil(log2(MAX_SAMPLES+1))+5+5*MAX_SAMPLES` clocks (339 default,
1303 maximum). It includes final kept processing; a masked last is faster.
Unbounded input or output stalls imply no finite end-to-end deadline. Binary
search cycle cost and witness replay are part of service throughput.

## Offline use and bounded verification

`files.f` is the entire production dependency list. The default `example/trend64.sv`
is a directly connectable ordinary ready/valid instance. Root LICENSE/NOTICE
apply; SOURCES.md records actual fixed upstream source/full-license inspection,
semantic deduplication and independent implementation boundaries.

Run `python -B cores/acceleration/longest_increasing_subsequence/sim/run.py`.
The runner prefers the repository OSS CAD suite and imposes a hard 20-second
timeout per compiler/simulator child. TEST_PLAN.json freezes six profiles,
finite vectors and reset scope before the first HDL check. A timeout is
terminal and cannot be retried, narrowed or given more time. Successful
numerical matrices are not rerun for packaging changes.

The independent oracle treats index/value comparisons as DAG edges and computes
longest path lengths in O(n^2); small sequences additionally enumerate all
subsequences. Every committed sample checks independent ending/overall prefix
lengths. Output checks optimum length, original value/index membership,
strictness, order, count, markers, tag and canonical errors. It does not copy
the binary tail search, memory schedule or traceback. Tests include full signed
extrema, duplicates, exhaustive small alphabets, maximum lengths, masked holes,
all four error patterns, output stalls and immediate reset/fresh recovery at
every reachable state. N1 cannot reach nonempty binary comparison or predecessor
read, so those two states are explicitly excluded there. Fresh recovery uses a
complete maximum-length ascending sequence after each reset. Main counters
exclude these separate reset/recovery transactions.

`verification.json` is the authoritative current hash-bound maturity/evidence
record. Only the fixed finite tests may justify UNIT_SIM_PASS; synthesis, PnR,
STA, board tests and expanded regression are NOT_RUN. All physical status is
HW_UNVERIFIED, and this package has no inherited hardware claim.

The qualified six-profile run checked 689 main frames, 11846 input tokens,
2935 output tokens, 10267 committed prefix DAG checks and 599 exhaustive
subsequence crosschecks. Every profile reaches its full valid length limit.
There were 114 immediate reset/fresh recovery pairs and six named parameter
rejections. Main-only activity: 31785 tail comparisons, 126072 cycles, 5146
held-output cycles and 100044 blocked-input cycles. Witnesses contained 2876
kept samples, including 1367 negative values; 547 valid frames required a
proper subsequence. A first TB compile exited successfully but emitted a
missing-timescale warning; that ordinary failed qualification attempt is
retained, then explicit RTL/example time units fixed it before any simulation.
The first numerical matrix passed, but independent review confirmed that its
reset helper allowed one active edge after target observation. That receipt
and all original hashes are archived as an ordinary coverage defect; the TB
now asserts reset on the observed low-clock boundary. The exact unchanged
finite matrix was requalified for this concrete concern, with all 114 immediate
reset/fresh pairs passing and no RTL/oracle/vector/plan change or timeout.
The runner's valid-only maximum-length summary had also been corrected before
this requalification. Current tested hashes bind the corrected TB and runner;
the final README-only results refresh updates current hashes without another
numerical rerun. Two earlier attempts remain explicit historical evidence.
