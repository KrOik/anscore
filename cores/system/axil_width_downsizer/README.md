# AXI-Lite width downsizer

This independently authored AXI-Lite bridge converts one aligned wide access
into addressed narrow-word transactions. It preserves byte lanes and protection
bits, skips write words with no active strobes, assembles every read word and
reports the most severe downstream response. Existing ANSCORE stream width
adapters carry no addresses or read/write response ownership and cannot provide
this service. Production sources and the example are self-contained.

## Parameters and port contract

`S_DATA_W` is 16,32 or64 (default32); `M_DATA_W` is8,16 or32 (default8), strictly
less than S_DATA_W. Let S=S_DATA_W/8 bytes, M=M_DATA_W/8 bytes and R=S/M.
`ADDR_W` is every integer from `clog2(S)` through64 (default16). Unsupported
settings elaborate `axil_width_downsizer_invalid_parameters__see_README`.
Every data/address pattern is unsigned. There is no fixed point, rounding,
saturation or host-side data preparation.

All ports share rising-edge `clk`. `rst` is synchronous active-high and has
priority over all state updates. Both endpoint devices must be reset together:
reset cancels upstream buffers, downstream work and held responses. A reset
cannot undo writes already accepted by the target. Request valids and ready
outputs are gated low immediately while rst=1. Registered upstream response
valids `s_bvalid` and `s_rvalid` clear on the rising edge with rst=1; no transfer
is accepted while reset is asserted. There is no CE, CDC, runtime configuration or frame marker.
Every AXI-Lite transaction is a single access. Transfers use `valid && ready`
on an edge with rst=0. A blocked producer retains valid and every payload bit.

`s_*` is the upstream slave and `m_*` the downstream master. Both expose the
five usual AXI-Lite channels: AW has ADDR_W address and three protection bits;
W has its interface's data width and one strobe per byte; B has two response
bits; AR has ADDR_W address and three protection bits; R has data and two
response bits. There are no IDs, burst lengths, exclusive monitors or address
translation. One read and one write may proceed concurrently and independently;
each direction has one outstanding upstream access. AW/W are buffered
individually and pair in acceptance order, so either may arrive first. No
write reaches the target until both halves have arrived.

Upstream addresses must be aligned to S bytes. A misaligned read returns local
DECERR and zero data; a misaligned write returns local DECERR even if all its
strobes are zero. Both cause zero downstream transactions. Every aligned base
is legal, including the highest aligned base in the full ADDR_W domain. This
alignment guarantees that all narrow addresses fit without wraparound.

For an aligned address A, narrow part i has byte address `A+i*M`, protection
copied from the original address channel, data from wide bits
`[i*M_DATA_W +: M_DATA_W]`, and strobes from `[i*M +: M]`. Part0 is first.
Byte lane j carries bits `[8*j +: 8]`; this is a byte-lane convention without
an endian-swapping operation. A zero-strobe narrow write is omitted entirely.
An aligned all-zero-strobe write returns local OKAY without touching the
target. Reads always fetch all R narrow words and concatenate them in the
same lane order, including returned data on an error response.

Every issued write part waits for its AW and W to be accepted independently,
then for its B response, before the next nonempty part is sent. Reads wait for
each R reply before the next AR. The response aggregate is the numeric maximum:
DECERR(3)>SLVERR(2)>EXOKAY(1)>OKAY(0). A downstream error does not cancel the
remaining parts. AXI-Lite targets ordinarily use OKAY/SLVERR/DECERR; EXOKAY is
preserved defensively and is not an exclusive-access guarantee. An access
split into several target operations is **not atomic**: earlier writes may
already have taken effect when a later error is returned, and a read is not a
simultaneous snapshot. Use with ordinary memory/registers whose access-width
side effects are acceptable. No retry, rollback or timeout is implemented.

An upstream response becomes valid only after the final required reply (or
local validation/zero-strobe processing). It remains stable through arbitrary
upstream stalls. That direction accepts no next request until the held
response retires; there is no retirement-edge fallthrough. A missing AW/W
counterpart or downstream response can stall indefinitely. Unsolicited replies
are not acknowledged when there is no owning part. This service assumes AXI
ordering and stable target responses and is not a protocol-fault detector.

## Schedule and architecture

Each direction has fixed payload registers and a part index. The write FSM
adds one scan cycle per visited part to skip empty strobe groups. After both
upstream write halves are stored, a dispatch edge enters the scan; each active
part needs one SEND cycle for simultaneous AW/W handshakes and a later cycle
for its B handshake. Thus with an always-ready target whose B response is
available immediately after the address/data edge, all-active write response
valid occurs within `1+3*R` edges after the later upstream acceptance. A read's
AR is registered and each part takes an AR edge followed by an R edge; with
that analogous target behavior, read response valid occurs after `2*R` edges
from upstream AR acceptance. Target and upstream stalls add to these counts.
The contract gives no unqualified transaction-completion deadline.

Storage grows linearly with interface width: wide write/data/strobes and wide
read accumulator/output plus addresses and small control. There are no RAM
arrays, variable-size searches, vendor primitives, DSPs, external memory,
generated tables or memory initialization files. Multiplication in address
expressions is by M, a power-of-two constant. Architecture risk is **LOW** for
the supported widths; part selection and address adders are likely control
paths. This is qualitative source review, not measured area, timing, power,
FPGA fit or hardware throughput.

`files.f` and `example/files.f` resolve from this package root. The standalone
`example/axil_narrow_peripheral.v` exposes every port at default32-to8 settings.
Compile it with the listed production source and connect its narrow side to a
same-clock target with shared reset. No CE-qualified stream can be directly
substituted for these AXI channels.

## Finite verification

Run `python cores/system/axil_width_downsizer/run_tests.py` from the repository
root. The runner uses verified absolute OSS-suite paths, freezes exact input
copies before execution, hashes source/tool/raw bytes and applies a20-second
child watchdog with process-tree termination and bounded cleanup. Missing
tools or any failed/timed-out check stop subsequent child execution. There is
no automatic retry. `--profile` selects one of four fixed profiles for targeted
follow-up; no broader search is performed. Successful and failed local images
stay in ignored task-specific `.build/` directories for root-owned review and
cleanup. Raw receipts and source snapshots remain in timestamped `reports/`.

The deterministic TB compares narrow addresses, protection/data/strobe slices
against the original wide command and compares assembled reads with an
independent byte-address function. It checks both AW/W arrival orders,
concurrent reads/writes, all byte strobes individually, skipped/zero-strobe
writes, all two-bit responses and severity precedence, local alignment errors,
the highest legal base, source/sink stalls and shared reset in partial input,
active work and held responses. The four fixed parameter profiles include the
minimum address domain, ratio8 and64-bit addresses/data. Actual execution
status is recorded separately in `QUALIFICATION.md`; preparation of a TB is
not a PASS. All hardware remains HW_UNVERIFIED. Provenance is in `SOURCES.md`.
