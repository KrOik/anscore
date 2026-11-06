# Pre-execution source and architecture review

This record describes static reasoning, not numerical or HDL execution.

- Full32 command values are rejected before L/H/r narrowing. The upper center
  product retains36 bits, including all32 high-bin bits times the validated
  low4 harmonic bits; any invalid high H bits separately reject the command.
  Radius spacing retains33 bits and the safe half-size shift never uses an
  invalid shift count. Legal `k0>=2r+1`, `H*k0+r<N/2` proves disjoint interior
  windows. Inactive windows map to a forced-zero DC RAM slot.
- Every spectrum address is written in the current completed collection before
  replay. RAM has one synchronous read register, explicit valid/ready holding,
  no reset and no simultaneous collection/replay. The final read is consumed
  exactly once, then the band monitor's pipelined final addition is flushed
  before its first output. Core and band SUM_W expressions agree for the
  power-of-two half-capacity, including minimum Lmax4.
- Input index is MAX_LOG2N bits, length/read counts MAX_LOG2N+1, public received
  count13. N4096 and half-length2048 are representable. No negative-frequency,
  DC or Nyquist power enters total. Masked peak search still consumes exactly
  N bins. A zero selected peak is an explicit error, even if other bins have
  power. Earliest nonzero ties follow the unchanged helper.
- All exact sums fit SUM_W<=43; disjoint bands partition the total. Divider
  operands have a leading zero, numerator includes all16 fractional shift
  bits, remainder comparison is unchanged, and output width SUM_W+17 holds
  every legal positive RNE value without saturation. Zero denominators are
  skipped with explicit valid0; zero numerator with positive denominator is
  a valid rounded zero. The divider runs at most3 times per record.
- Band tag/status/last/index and divider flags are checked. Every error zeros
  the entire numerical bundle while preserving command and count. Registered
  helper reset during an error response flushes old partial helper state
  before another command. Output data/control change only before OUTPUT or
  after its retirement/reset, so the held bundle is stable.
- Reset cancellation does not clear RAM; only completed fresh data is read.
  Public ready/valid mask rst. Peak/divider/magnitude resets are synchronous
  active-low, driven through a registered local fence; band reset is synchronous
  active-high. There is no new CDC, vendor primitive, combinational
  division, unbounded dynamic state, real arithmetic or simulation delay in
  production RTL.
- I/Q marker/invalid metadata traverses four positions under the same global
  advance condition as mag_squared. The wrapper accepts no bin after an
  accepted LAST or N bins, so malformed ending cannot leave younger words in
  the helper. Shift remains reset0; no independent configuration races exist.
- Service accounting: peak cfg/wait2, N collection, peak response1, windows<=8,
  band command1, synchronous read fill1, half-spectrum replay, flush2,
  band responses<=16, classification1, three divider sequences<=3*62,
  final state/transfer and control margins fit N+N/2+320. I/Q adds4 cycles.
  Collection II1 does not imply unrestricted continuous-frame throughput.

Qualitative resource risk is MEDIUM. Logical RAM512B default/8KiB maximum,
  eight bounded old band accumulators and one iterative divider are structurally
bounded. The old32-by-INDEX_W band moment multiply remains; the configuration
factor product is32-by-4, and the actual I/Q chain retains two16-by-16 squares.
No removal of unused moment logic is assumed. Resource mapping and timing are
unmeasured. No synthesis/PnR/STA/board/PPA was performed.

The frozen integer set oracle and TB are independent of helper recurrence.
The TB's blocked configuration source is the next real vector; it retains
valid and the entire payload through old-result retirement and until actual
acceptance, with a held-source assertion. Completed preparation/HDL child
records are persisted before metadata parsing, and simulation inputs are
checked against the saved compile-image digest before each launch.
Four preparations and10 HDL children may run only after the root reviews the
entire sealed closure and explicitly authorizes that exact finite plan.
