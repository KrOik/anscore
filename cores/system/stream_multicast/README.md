# Selective packet stream multicast

`stream_multicast` duplicates a packet to any subset of independent standard
ready/valid consumers. Each selected consumer receives each beat exactly once,
even when consumers pause independently. The destination mask is sampled on the
first accepted beat and remains fixed through the packet. This adds a selective
one-to-many stream operation to the existing many-to-one arbiter and single
destination frame switch.

## Interface and parameters

All ports use one rising-edge clock. `rst_n` is asynchronous active-low reset;
reset discards buffered copies and the current packet selection. The system must
coordinate reset of peers when discarding a partial packet. There is **no CE**:
every edge with `valid && ready` transfers. A CE-qualified ANSCORE stream must
use a semantics adapter before connection; freezing only a producer's state
while it still advertises VALID is incorrect.

| Parameter | Legal values | Default |
| --- | --- | --- |
| `PORTS` | integer >= 1 | 3 |
| `DATA_WIDTH` | positive whole bytes, >= 8 | 32 |
| `USER_WIDTH` | integer >= 1 | 1 |

Input `s_data`, byte lane mask `s_keep`, arbitrary metadata `s_user`, `s_last`,
and `s_mask` are sampled only on `s_valid && s_ready`. Keep bits correspond to
data lanes `[8*i +: 8]`. Data and USER are opaque bit fields with no prescribed
signed or fixed-point interpretation. Every KEEP pattern, including zero, is
passed unchanged. LAST=1 ends a packet, including a one-beat packet. Packet
length has no fixed limit; a missing LAST keeps the captured destination mask.
For a new packet, bit `i` in `s_mask` selects output `i`; later beat masks are
ignored. A zero mask discards every beat through LAST without producing output.
The source must keep payload and mask stable while `s_valid && !s_ready`.

Output vectors concatenate port `i` at offset `i*width` (port zero is the low
slice). Every `m_valid[i] && m_ready[i]` consumes one copy. A consumer that has
already accepted a copy sees VALID clear until a later beat is available, even
if another consumer is still stalled. DATA, KEEP, USER, LAST and VALID remain
stable for each stalled valid output. Invalid output payload is unspecified.

The core holds one shared payload and a per-destination pending bitmap. A new
beat may replace the stored beat on the same edge that all remaining copies
drain. First output is visible one clock after input acceptance. All selected
consumers continuously ready permit one input beat per clock. Independently
stalled consumers limit subsequent input acceptance to the slowest selected
consumer; unselected outputs never exert backpressure. There is no finite
completion bound for an indefinitely stalled selected output. Changing `s_mask`
affects the next accepted packet only. No command/completion, memory, address,
CDC, error response, external ROM or vendor primitive is present.

## Use offline

Run from this directory with `iverilog -g2012 -tnull -s stream_multicast -c files.f`.
`files.f` lists the complete production source closure. The standalone
`examples/multicast_2way.v` connects a 32-bit source to two independent consumers;
compile it alongside `files.f`. No downloaded source or generator is required.

Run from the repository root:

```powershell
python -B cores/system/stream_multicast/run_checks.py
```

The runner first uses `IVERILOG`/`VVP` environment overrides if supplied, then the
repository's local OSS CAD Suite when present, then PATH. Each tool call has a
20-second limit. Temporary binaries are removed by `TemporaryDirectory`.
The small source-bound `check_results.json` records actual commands, outcomes,
tool paths and SHA-256 values. Missing tools or timeouts do not count as passes.

## Architecture and evidence boundary

Default qualitative resource risk is **LOW**: one 38-bit payload (32 data +
4 KEEP + 1 USER + LAST), two 3-bit routing bitmaps and one packet-state bit.
No DSP, array RAM, external memory or derived clock is required. At large PORTS,
shared payload fanout and the `m_ready` reduction feeding `s_ready` have
**MEDIUM** timing/routing risk; parameter growth is linear in PORTS and payload
width. This is structural review, not measured area, frequency or power.

Current status: **LINT_PASS** (Icarus syntax/elaboration, not a separate lint
engine), **UNIT_SIM_PASS**, **HW_UNVERIFIED**. The example is a minimal connection
candidate, with no separate system hardware qualification. The deterministic
per-output FIFO scoreboard checks normal payload/KEEP/USER/LAST order, all-ready
replacement, independent stalls and stalled-field stability, packet mask changes,
zero-destination packet drops, one-beat packets, and reset cancellation of a
partially delivered packet. Tested PORTS/DATA_WIDTH are 1/8, 3/16 and 5/32;
unlisted parameter combinations are not proven. Synthesis, PnR, STA and board
checks were deliberately NOT_RUN.

`SOURCES.md` records semantic de-duplication and the fixed-version upstream
comparison. The implementation is original Apache-2.0 code under the repository
license; no third-party source was imported.
