# Architecture and numerical review before execution

The task is one bounded unsorted limit-book indication, not allocation. A fully
parallel N-by-N compare/reduce structure expands comparators, summation trees
and operand routing quadratically. Sorting plus prefix/suffix curves can reduce
evaluation work but needs an additional bounded sorter/merge contract and data
movement. The selected first version reuses one sequential row port and four
exact accumulators across all candidates. N<=64 bounds the work; accepting raw
unsorted levels avoids host-computed curves or preselected answers.

The packed row array has MAX_ROWS*(1+PRICE_W+QTY_W) logical bits:2080 at core
defaults,4160 at maximum. It has one load write or one registered read in a cycle;
no simultaneous load/evaluation, array reset, unrolled N-way read, multiplier,
divider, vendor primitive or external memory is required. Storage inference and
physical RAM packing remain tool dependent. A registered row is accumulated in
a separate state; EVALUATE uses completed accumulators, and FINISH follows the
last candidate update so nonblocking assignments cannot drop a winning tail.

SUM_W=QTY_W+clog2(MAX_ROWS+1) covers N*(2^QTY_W-1), including duplicated levels.
The four cumulative quantities are unsigned. Magnitude imbalance compares two
unsigned sums; only the final difference enters a signed SUM_W+1-bit result.
Unsigned price-distance subtraction always subtracts the smaller value from the
larger, with no absolute-value overflow. Zero and all-one prices are ordinary.

Per candidate: one read/capture pair,2*N row read/accumulate cycles and one
comparison/selection cycle. Include N load transfers and one final response
stage:2*N*N+4*N+1 no-stall cycles from header. Input gaps, output hold and response
retirement are separate. Default N32 is2177 cycles; maximum N64 is8449. These
are source-derived cycle counts, not measured throughput or timing.

The actual LEVELS8 composition adds a16-row,1040-bit scratch snapshot to the
unchanged two-sided book's1024 logical row bits (the book rounds rows to bytes).
At LEVELS32/full widths the corresponding totals are4160+4096=8256 bits, plus
the existing dictionary/control and new scan/response registers. Public ranked
DEPTH rescans a side internally, so obtaining all ranks is O(LEVELS^2) rather
than a free streaming snapshot. This deliberate reuse preserves mature storage
and exact interface semantics. The finite bounded depth is suitable for an
indicative periodic service; no market-feed line-rate claim is made.

Expected longest paths are a registered row's price comparison and quantity
accumulation, and the EVALUATE magnitude/distance lexicographic selection. The
states split memory access, accumulation and candidate selection. Qualitative
risk is LOW for bounded logical storage/no DSP demand and MEDIUM for candidate
latency, small-RAM packing and actual critical-path mapping. No synthesis, LUT,
BRAM/DSP count, Fmax, power, PnR, STA or board result is available.

Reset/hold checks target partial snapshot loading, core evaluation and held
results. Actual-book checks additionally reset the private count query and
private ranked-depth walk and a committed held maintenance reply. The two
controllers share reset and the exclusive owner prevents torn snapshots.
