# Finite RTL qualification

Status: **FINITE_RTL_SIM_PASS / FINITE_REAL_ADAPTER_SIM_PASS / HW_UNVERIFIED**.
The sealed README/architecture/plan draft preserve their pre-execution candidate
state; this additive record supplies the executed result. One approved attempt
ran under gate B49_FFT_FIR_ONCE_01. It completed on2026-11-07 Asia/Shanghai with
4 vector preparations and11 HDL children (3 syntax,4 compile,4 simulation), all
PASS. There was no retry, timeout, termination helper, active child or failure.

Receipt: `reports/20261106T185726607567Z/results.json`
SHA256:`404c920f9609d6371e8023a386c56b8e00155914b4e33090827875ca611db718`.
All17 current/archived source entries,29 tools and final controls remained pinned.
Actual baseline HEAD and inherited/effective PATH hashes were bound. Fifteen
exclusive initial records,15 terminal records,15 separate validated records,
30 raw streams,8 fixture files and4 retained simulation images remain intact.
The aggregate child list intentionally retains terminal process evidence;
observed/expected counters belong to the separate validated sidecars.

| Profile | N / width / tag | Configs | Commands | Actual inputs | Numeric outputs | Markers | Holds | Clock edges |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| tiny |2 /8 /1|25|47|49|49|20|266|3590|
| ragged |8 /12 /8|29|81|245|285|38|1129|45768|
| maximum |256 /24 /32|29|76|7870|8130|35|28610|2193556|
| real adapter |64 /16 /8|28|80|1903|2223|38|7688|2040596|
| total | |111|284|10067|10687|131|37693|4283510|

These are fixture/main-loop counters. They include921 accepted tap inputs and
4 fixture resets. In addition, each profile completed11 directed resets, giving
44 directed resets including the four initial resets. Directed setup/response
traffic is excluded from the fixture counts above. The preparations completed31
separate exact known time-domain response assertions covering2576 samples.

The general payload/flag oracle independently uses recursive natural arrays,
direct85-digit Decimal roots, signed-magnitude RNE and the specified staged
fixed-point coefficient FFT/product/IFFT chain. Known zero/unit/sign/gain,
constant and half-frame delay/sum responses constrain selected exactly
representable cases through separate integer time-domain convolution. Arbitrary
ideal convolution or an arbitrary integer FFT round trip is not claimed exact.

The corpus covers persistent filtering, nonpower tap counts, M1, MN, startup
zeros, restart, rejected configuration preservation, successful publication and
history reset, short final blocks, zero-input tails, empty-end markers, full32
invalid commands, malformed tap/data LAST, accepted invalid inputs, signed
extrema, fractional rounding, source gaps, output/reply stalls, live-port changes,
tag capture, index/LAST/counts and reset recovery. Directed cuts cover coefficient
capture/FFT/reply, sample capture, data FFT, shared complex product, inverse FFT,
held output, history copy and the start of an automatic multi-block tail.

**Coverage limit:** complete M=N tails close at N2/N8/N64. The maximum N256
profile covers M=N persistent processing/history and a first-block tail reset,
but excludes its entire256-block tail within one20-second child. A final
N256-output command with M=N/2+1 exercises the maximum output-counter extent
in two blocks. This is not an extrapolated pass for the excluded conjunction.
Unexpected internal FFT protocol-fault paths were source reviewed, not fault
injected. The finite corpus is not a theorem over every frame, stall or reset.

Source resource budget: one reused DATA_W-by18 real multiplier and one new
shared DATA_W-by-DATA_W multiplier, plus four complex N-word RAMs including the
FFT state. Logical payload is8192 bits at default64/16 and49152 bits at maximum
256/24, before scalar registers/ROM. These are source estimates, not mapped
DSP/BRAM counts. Physical packing/multiplier mapping risk is MEDIUM; serial
latency risk is HIGH; device fit is UNKNOWN because no target part is specified.
M=N finite tails require N transform blocks. Unbounded backpressure has no
completion-time or sample-rate guarantee. Observed simulator wall time is not
hardware timing evidence.

The necessary original workspace FFT source is explicitly admitted unchanged
at its original path/hash; baseline_absent=true remains material. Its embedded
ROM completes offline elaboration. No old FFT driver/report/hardware conclusion
is inherited. No synthesis, mapping, PnR, STA, board, bitstream or power test ran.

POST_AUTHOR_AUDIT.json is a source-author receipt readback, explicitly not an
independent peer audit; it rechecks158 files. POST_ROOT_AUDIT.json separately
records the independent root readback. POST_PEER_AUDIT.json separately records
worker_a's completed independent post-audit (PASS_AUDITED). Its SHA256 is
`192c1841f3623e5083554b91982245da8644e8b2dcc82bf18c97b2f0e3bdf670`.
Root and independent worker_a also completed the pre-execution full-source/final
pin review in SOURCE_REVIEW.json. The8 unapproved pre-execution
revision files under review_revisions/01 remain workspace-only historical
metadata, excluded from the formal deliverable and staging; they were not run
and are not acceptance evidence.
