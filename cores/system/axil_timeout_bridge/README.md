# AXI-Lite timeout bridge

`LINT_PASS + UNIT_SIM_PASS + HW_UNVERIFIED` for the finite configurations in
`QUALIFICATION.md`. This independently authored bridge bounds the time until a
response becomes valid, quarantines a timed-out direction, and services later
requests with local `SLVERR`. It has a complete offline RTL dependency closure.

## Contract

All ports share rising-edge `clk`. `rst_n` is asynchronous active-low; assert it
for the bridge and protected slave together, and release it synchronously to
`clk`. Reset discards buffered commands, pending downstream requests, responses
and faults. A bridge-only reset cannot safely recover a slave that still owns
an old request. There is no CE, CDC, runtime configuration, or frame/packet
marker. Each AXI-Lite read or write is one complete transaction.

Parameters are `ADDR_W=16` (every integer 1..64), `DATA_W=32` (multiples of 8 from
8 through 64), and `TIMEOUT_CYCLES=16` (every integer 1..65536). Unsupported
settings elaborate a named missing module. All addresses and data are unsigned
bit patterns; no alignment/range checks, fixed point, signed interpretation,
rounding or memory address translation is performed. Every `DATA_W/8` byte
strobe bit and each three-bit protection field is passed unchanged.

The `s_*` port group is the upstream AXI-Lite slave, and `m_*` the downstream
master. Both have conventional AW(address/protection), W(data/byte strobes),
B(two-bit response), AR(address/protection) and R(data/two-bit response)
channels. Every transfer is exactly `valid && ready`; the source holds all
fields and valid until transfer. `write_fault` and `read_fault` are separate,
sticky, reset-only timeout indications. All ready/valid outputs are low during
reset; other payloads are only meaningful while valid.

One read and one write can be outstanding concurrently. AW and W each have a
one-entry buffer, accept in either order, and are paired in acceptance order.
There is no write dispatch until both halves have arrived. While waiting for
a missing counterpart, no write timer runs: an unpaired upstream write has
no bounded completion guarantee. The complete write is dispatched on the
first rising edge after both buffers are full. At that edge its timer starts
at zero and downstream request valids become visible. The read timer starts
at zero on the upstream AR acceptance edge; downstream ARVALID is registered.

On the `TIMEOUT_CYCLES`-th later rising edge, if no downstream response
transfers on that same edge, the bridge registers upstream `SLVERR` (`2'b10`),
sets the direction's fault, and returns zero read data. A downstream response
transfer on that final allowed edge wins over the timer. Healthy responses
preserve all two response bits and all read data bits, including error replies.
Normal downstream response acceptance requires the preceding AW and W, or AR,
handshakes to have completed on earlier edges. Consequently a timeout of one
cycle intentionally times out even an always-ready target under this
registered schedule. `TIMEOUT_CYCLES>=2` permits the earliest normal response.

An upstream response is registered at its downstream response handshake and
can be consumed on the following edge. The sink may stall indefinitely:
response valid, data and response code remain stable and the timer stops.
No same-edge response-retirement request fallthrough is provided. Except for
paired AW/W buffering, a direction accepts its next transaction only after
its previous response has retired. A post-fault read produces local SLVERR on
its AR acceptance edge. A post-fault write produces local SLVERR on the edge
after both halves have been collected. Unlimited upstream backpressure gives
no unconditional wall-clock transaction-completion bound.

## Timeout and late side effects

Timeout does not cancel a downstream write or undo a side effect. Original
AWVALID, WVALID and ARVALID remain asserted with their original payload until
their own handshakes, even after the upstream timeout response has retired.
Separate downstream payload registers prevent later quarantined commands
from changing that original request. Its one eventual B/R reply is drained
and discarded. Later requests never dispatch downstream in that direction,
even after the original drains. The opposite direction continues independently.

The bridge assumes the slave follows AXI ordering and payload stability; it
detects response timeouts, not every AXI protocol violation. Unsolicited or
duplicate downstream responses are not forwarded or acknowledged when there
is no owning request. This is a watchdog and quarantine service, not a
protocol checker or a safe retry policy for writes with uncertain completion.

## Architecture and use

The implementation uses small fixed payload registers and two bounded
counters. It has no RAM, vendor primitive, multiplier, external memory,
initialization file or generated dependency. Timers are
`max(1,clog2(TIMEOUT_CYCLES))` bits and count only until completion/timeout.
The maximum legal defaults and endpoint widths do not cause array expansion.
Architecture risk is **LOW** at defaults: the likely control path is
timer comparison and registered-response selection; it is a structural
assessment, not measured area/timing/power or a device-fit result. The
registered service deliberately favors bounded storage and simple ownership
over one-request-per-cycle throughput.

From this package root, `files.f` lists all production RTL. The standalone
`example/axil_guard_example.v` exposes both AXI-Lite sides and fault outputs
at default parameters; `example/files.f` is also resolved from the package
root. Connect the `m_*` ports to a same-clock AXI-Lite slave and use its shared
reset. Do not directly connect an ANSCORE CE-qualified stream to these AXI
channels.

Run the limited checks with `python run_tests.py` or
`python run_tests.py --tool-bin /path/to/iverilog/bin`. Python 3, Icarus Verilog
and vvp are test-only dependencies. Each child has a hard 20-second limit;
the runner writes timestamped raw logs and source hashes under `reports/`,
and simulator images under ignored `.build/`. No upstream code or network
is needed for compilation, simulation or use. See `SOURCES.md` for provenance.
