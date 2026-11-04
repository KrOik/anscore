# All-pole IIR lattice synthesis

`iir_lattice_synthesis` filters an excitation stream using configurable
reflection coefficients. Its descending-stage lattice implements an arbitrary
1..8-order all-pole predictor synthesis filter. This complements the repository's
Levinson-Durbin coefficient estimator and differs from direct FIR/LMS and
biquad/SOS datapaths. No existing RTL was modified.

## Fixed-point recurrence

For P=ORDER and S=2^FRAC, coefficients k[1..P] are signed integer codes with
FRAC fractional bits. Let tz divide a signed integer toward zero and sat clamp
to the signed STATE_W range. The persistent backward states are b[0..P-1].
One input excitation e[n] is sign-extended into STATE_W bits and processed as:

```text
f = e[n]
for m = P down to 1:
    old = b[m-1] from the preceding sample
    f = sat(f - tz(k[m]*old/S))
    if m < P:
        new_b[m] = sat(old + tz(k[m]*f/S))
new_b[0] = f
y[n] = f
```

Every backward update uses the newly computed, already saturated f and the
previous sample's old b[m-1]. The stage-order schedule consumes an old backward
state before any lower stage overwrites it. b[P] is unnecessary for an all-pole
output and is not calculated or stored. Each product is kept exact until its
single toward-zero division by S. Negative products do not use floor rounding.

`m_data` is the signed STATE_W-bit output code. Input/state/output share the
same units; the core does not impose a sample fractional scale or multiply
the excitation by S. `m_clipped=1` if **any** forward or stored backward state
of this sample saturates, even when the output itself is in range. It clears
for each new sample. There is no modular arithmetic, hidden output truncation
or separate numerical error response.

In ideal arithmetic, |k[m]|<1 yields a stable all-pole model. For P=1,
`y[n]=e[n]-k[1]*y[n-1]`. For higher orders its denominator follows the same
step-up coefficient convention as `levinson_durbin`. Quantized states and
saturation change that ideal response; no universal error, overflow-free
operation or absence-of-limit-cycle claim is made. Guard bits and excitation
scaling are the caller's choices, and clipping is explicitly observable.

## Configuration and data interfaces

| Parameter | Default | Legal values |
| --- | ---: | --- |
| DATA_W | 16 | 2..24 |
| STATE_W | 24 | DATA_W..32 |
| FRAC | 16 | 1..20 |
| ORDER | 4 | 1..8 |
| TAG_W | 8 | 1..32 |

All ports use one rising-edge clk. rst is synchronous active high and overrides
work; assert it across a rising edge. Ready/valid outputs are suppressed while
reset is asserted. Reset cancels partial configuration, arithmetic and pending
output, clears configured, and requires a fresh successful configuration before
data can transfer. Arrays and multiplier scratch registers are not reset;
successful coefficient commit clears every backward state before use.
There is no CE, CDC, external memory/bus interface, address protocol or bus
error response. Invalid public parameters fail elaboration with the named
parameter-error instance. Derived localparams must not be overridden.

Configuration transfers on `c_valid && c_ready`. A complete group contains
exactly ORDER words in k[1],...,k[ORDER] order, with no index/last marker.
c_k is signed FRAC+1 bits, representing [-1,1-1/S]. The exact -1 code is
rejected; every other encoding satisfies the required strict |k|<1 bound.
Positive +1 cannot be represented on this port. The producer holds valid and
data stable until transfer. A missing group word pauses loading indefinitely;
reset is the way to abort or realign a partial group.

The shadow coefficient bank is invisible to sample processing. After the last
configuration word, a valid bank is committed one coefficient per cycle while
all history is cleared. Sample/configuration admission stays blocked during
commit. After ORDER commit clocks, configured is set and c_done pulses for one
clock with c_error=0. This commit is atomic from the data interface's viewpoint.
No sample can see a partially copied coefficient set or partially cleared state.

An invalid bank is rejected one clock after its last word: c_done pulses with
c_error=1. Active coefficients, backward history and prior configured state are
retained. If no model was configured, data remains blocked. The entire group
is consumed even when an early word is invalid. `c_done/c_error` are synchronous
notifications with **no ready input**; the controller must sample the pulse.
c_error retains the most recent result until the next configuration result or
reset; it is a status level, meaningful with c_done, rather than another pulse.
Parameters are static; coefficient groups
are the only runtime configuration.

While idle, configuration has priority over a simultaneous configuration and
sample offer. A configuration source cannot interrupt active sample arithmetic
or a pending result; it holds its first word until c_ready. While a group is
loading/committing, the sample source holds its sample until s_ready.
configured can retain its previous value during reconfiguration; admission
signals, rather than configured alone, determine when work may transfer.

Data transfer uses `s_valid && s_ready`; s_data, s_last and s_tag are captured
together. Each accepted sample yields exactly one ordered result transferring
on `m_valid && m_ready`. m_data, m_last, m_tag and m_clipped remain stable under
output backpressure. Source fields must remain stable until accepted. There
is one in-flight sample and no overlapped arithmetic. A new sample or model
group can start on the edge after the prior output transfers.

s_last is forwarded only as metadata; it does **not** clear filter history.
History persists across packet boundaries until a successful model commit or
reset. Tags are uninterpreted transaction metadata. Output fields are meaningful
only with m_valid. Input gaps and sink stalls may extend service indefinitely.

## Architecture, latency and resource review

One shift/add multiplier is shared across P forward and P-1 backward products.
The coefficient magnitude has FRAC bits because |k|<1. Its FRAC iterations
follow one setup clock per product. The full STATE_W-bit unsigned state magnitude
supports the most-negative state without signed absolute-value overflow.
Products use PW=STATE_W+FRAC+1 magnitude bits and an extra signed arithmetic
bit before saturation. High bits are compared to signed state limits before
the result is narrowed. No variable multiply/divide hardware operator is used.

Sample acceptance to output-valid latency is `(2*ORDER-1)*(FRAC+1)` clocks,
119 at defaults. Earliest output transfer is one edge later. With the sink
always ready and no intervening configuration, sample acceptance spacing is
two clocks longer than that latency (121 by default). Last-configuration-word
to c_done latency is ORDER clocks for valid banks and one for invalid banks.
These are source schedules, not measured frequency/throughput results.

Small active/shadow coefficient banks and the backward history deliberately use
register arrays with indexed reads. The final low-order stage can write two
distinct history entries together; BRAM inference is not assumed. Default
array capacity is `2*ORDER*(FRAC+1)+ORDER*STATE_W` = 232 bits; the maximum is
592 bits. Storage grows linearly with ORDER and state/coefficient width.
There is no frame RAM, ROM, vendor primitive or external storage dependency.

Qualitative architecture risk is **LOW** at defaults and **MEDIUM** for maximum
width/clock expectations. Expected critical paths are the shared product adder
and the widened stage add/subtract/saturation selection. No actual LUT/FF/DSP,
power, timing, physical fit or hardware throughput was measured. Stable model
coefficients alone do not ensure a chosen state width avoids clipping.

## Offline examples and real LPC composition

`files.f` lists the sole production RTL source. No includes, tables, generated
RTL or third-party IP are required. From this package directory:

```text
iverilog -g2012 -Wall -tnull -s iir_lattice_synthesis -f files.f
```

`example/lpc4_synthesis_example.sv` shows a standalone default instantiation.
It accepts four signed17 Q16 reflection codes, then signed16 excitation and
produces signed24 samples. Its two streaming endpoints obey the contracts above.

`example/lpc4_analysis_synthesis.sv` is an actual two-core connection, using
the sibling `../levinson_durbin/rtl/levinson_durbin.sv` plus this core. The
complete source closure is `integration.f`, relative to this package. Retain
that sibling source when taking the integration example offline; the core and
standalone example have no sibling dependency. The integration dependency's
current SHA256 is also recorded separately in verification.json.

The connection transfers **reflection** history, not the final LPC vector,
from a successful analysis block into the model bank. Failed analysis blocks
are fully drained without sending any coefficient to the filter; a one-cycle
model_rejected/model_error notification identifies their completion. Thus a
failed model retains the previous filter coefficients **and history**.
Successful models clear history at configuration_done. Analysis can proceed
while a prior model filters samples; the next model begins loading at a later
idle boundary. The caller schedules model changes if it needs a particular
packet boundary. No frame-boundary update policy is implicit in this example.

## Finite verification and maturity

Run from repository root:

```text
python -B cores/signal_processing/iir_lattice_synthesis/run_tests.py
```

Python 3 standard library and Icarus/vvp are needed for development checks.
The runner prefers the existing local OSS CAD Suite, prepends bin/lib paths,
and limits every tool process to 15 seconds. Task-specific temporary TB text
and executables are removed on exit. Its full deterministic TB generator is
local source, so no external vectors/network/package installation is needed.
LF checks and local .gitattributes keep verified and committed bytes aligned.
Failed reruns remove stale PASS reports.

The independent oracle copies the entire previous backward-state vector,
computes the mathematical stage recurrence with unbounded Python integers,
then replaces the vector. It does not reuse the RTL's in-place write schedule,
state machine, or product iteration. Exact outputs and per-sample clipping
flags must match; there is no tolerance-based numerical acceptance.

Five DATA_W/STATE_W/FRAC/ORDER/TAG_W profiles are checked:
2/2/1/1/1, 8/8/4/2/3, 16/24/16/4/8, 24/32/20/8/32 and 8/16/1/8/8.
Each has 402 samples and six model groups. Total finite coverage includes 2,010
sample outputs, 912 expected clipped samples, identity/impulse/random/extreme
inputs, negative-product truncation, +/-near-unit reflection, state guard bits,
last/tag forwarding, first/last-word invalid model groups, retained history on
rejection, cleared history on acceptance, configuration/sample priority,
unconfigured input blocking, source gaps/input mutation, sink stalls and reset
during configuration/arithmetic/held output. The low-FRAC wide-state profile
has no expected clips; the oracle's exact zero count is checked rather than
forcing artificial saturation in that profile. Ten illegal parameters are
rejected, and the default standalone example compiles.

The real LPC composition test supplies r=[16,8,4,2,1], then an excitation
impulse of 16. It verifies outputs 16,8,4,2,1,0,0,0 with sink stalls and markers.
A rejected r[0]=0 model inserted after the fourth output must preserve the
old AR(1) history and produce the fifth value 1. This finite eight-sample test
is not end-to-end validation for arbitrary LPC models or real recorded audio.

Actual tool version, commands, outputs, profile counts and current source
hashes are in verification.json. Maturity is **LINT_PASS + UNIT_SIM_PASS**;
the two-core example is an **INTEGRATION_CANDIDATE** and all RTL is
**HW_UNVERIFIED**. Synthesis, PnR, STA, full regression and hardware testing
were not run. No previous board evidence is claimed for these sources.
