# Tie-aware two-sample Mann-Whitney statistic

`mann_whitney_u` receives two interleaved groups of signed integer samples and
returns the exact Mann-Whitney U statistic, cross-group win/loss/tie counts and
a quantized rank-biserial effect. It performs the sample comparisons and tie
handling in RTL. It returns no p-value, null-distribution approximation,
critical threshold or significance conclusion.

Status: **LINT_PASS / UNIT_SIM_PASS / INTEGRATION_CANDIDATE / HW_UNVERIFIED**.
Only the finite checks in `verification.json` are qualified; no synthesis,
PnR, STA, board test or expanded regression has run.

## Exact statistic and rounding contract

Group bit 0 identifies A and bit 1 identifies B on **each** kept sample.
For every cross-group pair, C counts A>B, L counts A<B and T counts A=B.
With NA and NB retained members,

```text
D = NA*NB = C+L+T
U_A = C + T/2
m_u2 = 2*U_A = 2*C+T
r = (C-L)/D = m_u2/D - 1
m_rank_biserial = RNE(r*2^FRAC)
```

`m_u2/2` is the exact possibly half-integer U_A. The output `m_wins`,
`m_losses`, `m_ties` and `m_pairs` are C,L,T,D. Ties receive exactly half
credit; they are not broken by arrival order. U_A also equals the sum of
combined-sample average ranks of A minus NA*(NA+1)/2. No ranks or pair counts
are supplied by the host.

`m_rank_biserial` is signed FRAC+2 bits and represents a real value divided
by 2^FRAC. Positive means A tends to be larger under this explicitly chosen
orientation. RNE is nearest integer with exact ties to even. Both +1 and -1
are exactly representable. Every comparison/count is exact; only the final
division is rounded. For every error-free frame,

```text
abs(m_rank_biserial/2^FRAC - r) <= 1/(2*2^FRAC).
```

There is no saturation, denominator flooring, random tie breaking, continuity
correction or approximate rank assignment. A zero rounded effect can describe
a small nonzero exact effect. All cross-group ties give U_A=D/2 and r=0, a
valid descriptive result. Sampling assumptions and any later inference belong
to the consumer; this core supplies the descriptive quantities above.

## Framing, errors and reset

All ports share one rising-edge clock, synchronous active-high `rst` and
ordinary ready/valid. No CE, CDC or runtime configuration. A frame has at
least one accepted beat and ends at accepted `s_last`. Only `s_keep=1`
contributes a member; masked group/value fields are ignored. The first
accepted beat supplies the frame tag even when masked; later tags are ignored.
Group A/B membership remains significant on every kept beat. Source valid
and all fields stay stable until acceptance.

Exactly one result transfers on `m_valid&&m_ready`, and every field remains
stable under arbitrary backpressure. The next frame waits until that result
retires. There is no early prefix publication or interleaved frame ownership.
A missing tail waits for input or reset without a timeout.

| Error bit | Meaning |
| --- | --- |
| 0 | No retained member of A |
| 1 | No retained member of B |
| 2 | A kept member beyond `MAX_LEN` was accepted |

All flags are independent; an empty frame has bits 0 and 1 set. Retain the
first MAX_LEN kept members for diagnostic `m_count`, `m_count_a`, `m_count_b`.
These counts never wrap. On overcapacity, the missing-group predicates refer
to that retained prefix, not an unbounded tail. Additional beats drain through
the tail without comparisons or memory writes. Any error rejects the complete
frame: all five statistic counters and rank-biserial output are zero. First
tag, retained counts and all error bits remain diagnostic, not a partial test
result. A masked excess beat does not cause overflow. Missing groups never
issue division by zero.

Reset gates ready/valid low immediately; its active edge cancels collection,
sample scan, arithmetic, held result and a pending input offer. It clears all
counts/control and makes old RAM words unreachable. Sample RAM is not reset:
new entries overwrite the prefix before any later sample can read it. No
cancellation result is emitted. Output fields have meaning only while valid.

## Parameters, widths and architecture

| Parameter | Default | Legal values |
| --- | ---: | --- |
| `DATA_W=W` | 16 | 1..32, signed two's-complement integers |
| `MAX_LEN=M` | 32 | 1..128, including nonpowers of two |
| `FRAC=F` | 16 | 0..24 |
| `TAG_W` | 8 | 1..32 |

Derived widths are local, not public overrides. COUNT_W=max(1,clog2(M+1))
represents counts 0..M. Let P=floor(M^2/4), and
PAIR_W=max(1,clog2(2*P+1)). Since NA+NB<=M, D<=P; C,L,T<=D and U2<=2D<=2P,
so every exact statistic fits PAIR_W. The signed contrast C-L and positive
denominator use AW=PAIR_W+1 bits. The final divider has N=AW+F<=39 quotient
iterations and OUT_W=F+2, within all frozen arithmetic limits. Its result has
absolute value at most 2^F, so both signed output bounds are respected even
at F=0. No legal-domain divider flag is expected. Default PAIR_W/AW/N are
10/11/27, and maximum PAIR_W/AW/N are 14/15/39.

A synchronous RAM stores {group,value} for each retained sample. A new sample
is registered/written, then scans all previously retained entries, one read
and one check per entry. It never compares itself. Same-group pairs do not
contribute; opposite-group comparisons orient the result toward A regardless
of which group arrived last. Every unordered pair is examined once, and every
cross-group pair belongs to exactly one of C,L,T. Signed comparison naturally
handles the minimum negative value without absolute-value overflow.

One existing unchanged `fp_div_iter` from
`../dsp_isp_library/infra/fixedpoint/rtl/recip_div.sv` performs the final exact
rational RNE operation. No sorting network, histogram sized by value domain,
multiplier, square root, vendor primitive or generated memory table is used.
The only runtime comparisons are against one registered prior sample at a time.
There are no simultaneous RAM read/write accesses or read-during-write mode
dependencies. Both manifests include the complete old arithmetic source.

Logical sample storage is M*(W+1): **544 bits** by default and **4,224 bits**
at maximum, excluding scalar control, counters, read and arithmetic registers.
Qualitative resource risk is **LOW** by default, **MEDIUM** at maximum because
of RAM mapping, the 32-bit sample comparison and serialized work. No measured
LUT/FF/DSP/RAM count, Fmax, power or device-fit claim is made.

For a newly retained sample with k previous retained members, input II is
2k+2 clocks when the next input is waiting; masked/excess beats can transfer
on successive clocks. There are n*(n-1)/2 synchronous scan/check pairs per
frame, including same-group checks, so work is quadratic in retained count.
This favors a small shared comparator over one-sample-per-clock service.

Let N=PAIR_W+1+F. Periods from final input acceptance to first valid result:

| Tail kind | Error-free | Rejected |
| --- | ---: | ---: |
| Newly retained, with k prior members | 2k+N+4 | 2k+2 |
| Masked or excess drain tail | N+3 | 1 |

An excess tail is necessarily rejected. The finite TB checks this exact
schedule on every frame. Earliest transfer is one edge after valid; a new
frame can enter one period after result transfer. Missing input tails and
output stalls prevent an unconditional wall-clock retirement bound.

## Offline use and independent finite evidence

From this package directory:

```text
iverilog -g2012 -Wall -tnull -s mann_whitney_u -f files.f
iverilog -g2012 -Wall -tnull -s two_sample32 -f example/files.f
python -B run_tests.py
```

The example forwards every port for up to 32 signed16 samples with a Q16
rank-biserial result. It is an integration candidate by syntax compilation,
not an inferential statistics application. No network is needed after checkout.
New source is covered by root [LICENSE](../../../LICENSE) and
[NOTICE](../../../NOTICE); actual preflight is in [SOURCES.md](SOURCES.md).

The independent Python oracle sorts pooled observations and assigns average
combined ranks to equal-value runs. It derives U_A from A's rank sum, computes
cross-ties from per-value A/B histograms, and obtains C/L algebraically. It does
not repeat the RTL's nested scan or physical memory algorithm. Python Fraction
and its exact rational nearest-even round predict the final output and check
the half-LSB bound. The TB also checks D=NA*NB=C+L+T, count=NA+NB and the total
number of retained unordered scan pairs independently of the result oracle.

Six profiles cover W/M/F/T=1/1/0/1,2/4/0/3,3/5/1/8,8/7/8/8,16/32/16/8,
32/128/24/32. The small signed2 profile exhausts all value/group sequences of
length one through four; signed1 length one through three is also enumerated.
Fixtures include both endpoint effects, all/mixed ties, negative/zero/positive
values, group arrival permutations, balanced/unbalanced groups, full pair/count
bounds, rounding half-cases in both signs and directions, masks/tags, missing
groups, exact capacity and masked excess tails, overflow and simultaneous
errors, input bubbles and real source/output stalls.

Reset probes immediately cancel every reachable controller phase, including
pending synchronous reads/checks, finalization, divider launch, middle of
division and genuinely held normal/error results with stalled input offers.
A separate probe cancels overcapacity drain. Each cancellation is followed by
a fresh equal-valued A/B pair when M>=2, verifying overwrite/read isolation;
M=1 instead checks its required singleton missing-group rejection. No active
edge intervenes between observing the complete target and `reset_now`.
These are finite cancellation examples, not exhaustive reset proofs.

Every subprocess is limited to 15 seconds. Only local Icarus/vvp and standard
Python run; temporary vectors/simulator images are removed. Verification stores
actual tool results, source/dependency/vector hashes. Only the unchanged old
divider's missing-timescale warnings are permitted; other positive diagnostics
fail. Eight illegal parameter configurations must fail by named error instance.
All package text is strict UTF-8/LF. No other regression/physical flow runs.
