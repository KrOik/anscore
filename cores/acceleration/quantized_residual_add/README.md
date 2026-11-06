# Quantized residual branch fusion

Two independent U8 input streams produce signed8 interleaved tensor outputs.
Persistent per-channel metadata controls the exact operation:

```
t = (U8(A)-U8(za))*U16(Sa) + (U8(B)-U8(zb))*U16(Sb)
y = clamp_[signed8(min),signed8(max)](RNE(t/2^shift)+signed8(zo))
```

RNE means nearest with exact ties to even, also for negative numbers. Scales0
and shifts0..31 are legal. One rounding follows the exact sum, retaining branch
cancellation. This is an inference building block; exporter supplies metadata.
It does not claim compatibility with a particular software ADD quantizer.
Current status RTL_CANDIDATE / INTEGRATION_CANDIDATE / HW_UNVERIFIED; no execution
has yet occurred. [Architecture](ARCHITECTURE.md), [provenance](SOURCES.md).

One rising-edge clock, synchronous high reset, ordinary valid/ready, no CE/CDC.
Sources hold all fields while stalled. Reset masks all transfers immediately and
cancels state on a rising edge; metadata validity is cleared and reconfiguration
is required. Payload RAM is not reset. Consumers discard incomplete frames on
reset. No automatic timeout, replay or branch realignment is provided.

Config c_op0 writes all metadata for c_channel; c_op1 invalidates every channel
and ignores other fields.2/3 are unsupported. c_error0 success,1 index outside
MAX_CHANNELS,2 bad op,3 signed min>max. Errors preserve previous configuration.
One held c_rsp must retire before a new config/command. Config wins simultaneous
offers. Config is blocked throughout frame ownership.

Command captures pixels1..MAX_PIXELS, channels1..MAX_CHANNELS and opaque TAG_W
tag. A precheck requires every selected channel configured before admitting any
input. A/B each supply pixels*channels samples, pixel-major then channel order.
Independent one-beat buffers join samples by ordinal position, not arrival time.
A_LAST and B_LAST must each be true exactly on the final pair. No geometry
multiply, frame storage or source lockstep requirement exists.

Outputs carry signed8 data, zero-based m_pixel/m_channel, command tag, m_last on
the final pair, m_clip for activation clamping and m_inexact for discarded
nonzero numerator bits in the shift. m_clip includes signed8 saturation if the
full interval[-128,127] is configured. Payload and flags remain stable under
arbitrary output stalls. m_last/coordinates are meaningful only with m_valid.

The separate held completion owns the definitive frame result: rsp_error0 OK,
1 invalid geometry,2 missing channel config,3 malformed A/B LAST. It carries
tag, actual retired output count and rsp_bad_a/rsp_bad_b for error3. Shape/config
errors admit no input and emit no output. A LAST error is detected after both
members of that pair have been accepted; the offending pair emits no output.
An already retired prefix is provisional and must be discarded on error3.
The caller abandons both remaining source frames; no implicit drain occurs.
Completion follows last output retirement and blocks new ownership until it
retires. Missing source beats wait indefinitely. Reset is the only cancellation
when one branch never arrives. Final data and completion cannot handshake on
the same edge; next command cannot handshake on the completion edge.

Parameters MAX_CHANNELS1..64(default16), MAX_PIXELS1..4096(default256),
TAG_W1..32(default8). Full16-bit runtime fields are checked before indexing.
The largest legal frame has262144 pairs, using the same two input slots and
77*64-bit metadata. Structural budgets and source-derived II11 are in the
architecture note; these are not Fmax, mapped area or physical throughput.

`files.f` and `example/files.f` are resolved from this package directory, fully
offline. `example/signed8_residual.sv` boot-configures one channel for actual
signed8 branch addition using the unchanged core and exact XOR128 affine input
conversion. It forwards data and completion, including malformed-LAST errors.
No vendor primitives, downloaded models or ROM generation is required.
