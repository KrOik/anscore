# CSI-2 byte-stream packet receiver

`csi2_packet_rx.sv` implements the legacy CSI-2 two-bit virtual-channel packet
layer, from actual serialized header/payload/CRC bytes. It fills the layer
explicitly absent from `image/raw_unpack`: header ECC, VC/DT/word count,
short packets, long-packet CRC, and independent per-VC frame/line accounting.
The RTL is original. Four actually retrieved, pinned mature implementation
references, hashes and excerpts are in `references.json`.

This is not a D-PHY, lane aligner/deskewer, SoT detector, clock-domain crossing,
or extended-VC CSI-2 v2/v3 receiver. An upstream physical/link adapter must supply
already aligned bytes, in original packet byte order, beginning with Data ID.
It must buffer physical traffic because this receiver can exert backpressure.
It emits packet payload, not demosaiced pixels; connect RAW10/12 payload to the
existing unpacker after interpreting packet metadata.

## Command and streams

All transfers are `ce && valid && ready`; reset is synchronous active-low and
takes priority over CE. `start_valid/start_ready` starts one byte-stream session,
snapshots `cfg_check_sequence`, and clears counters/per-VC sequence state. Source
data/metadata must be held until transferred. `s_last` marks the last byte of the
entire session, not the last byte of each packet. Packets may be contiguous;
their boundaries follow corrected headers and word counts. A session must contain
at least one byte; abort terminates a session with no arriving bytes. Without
`s_last` or abort the receiver deliberately waits for the next packet.

For a valid accepted header, `h_valid/h_ready` transfers `h_vc[1:0]`, `h_dt[5:0]`,
`h_word_count[15:0]`, `h_short`, and `h_corrected`. Word count is the short-packet
data field for short packets. All metadata is immutable until handshake or
accepted abort/reset. No payload is consumed before the header is acknowledged.

Long-packet `m_data[7:0]/m_valid/m_ready` transfers exactly WC bytes, with
`m_first/m_last` on its first/final payload byte and `m_vc/m_dt` identifying the
packet. WC=0 transfers no payload but still requires both CRC bytes. The payload
register supplies a stable token under arbitrary CE gaps and backpressure.
The serial input/payload holding design is bounded-resource, not an II=1
throughput claim. Every long DT in 0x10..0x3f is transported as opaque bytes;
this does not validate whether a DT is standardized or its pixel syntax.

**Payload is provisional until the corresponding successful packet report.**
The CRC follows the payload on the wire, so a downstream consumer must be able
to discard the entire packet on any error, including already emitted bytes.
Likewise a whole image can require rollback after a later packet failure.
No on-chip whole-packet buffer or automatic rollback is claimed.

## ECC, CRC and short packets

The first three bytes are Data ID, WC/data low byte and WC/data high byte.
Header ECC protects these 24 bits with six standard parity bits. The receiver
corrects one error anywhere in those 30 protected bits, including parity-bit
errors, before interpreting VC/DT/WC. Noncorrectable syndromes reject the stream.
The two high ECC byte bits are reserved in this legacy format and must be zero;
they are checked and rejected, not treated as protected/correctable bits.
All protected two-bit errors are detected; three or more errors have no
SECDED guarantee and can be miscorrected. This is not cryptographic integrity.

CRC-16 uses polynomial x^16+x^12+x^5+1 (reflected 0x8408), initial 0xffff,
payload bytes and bits in wire order, no final XOR, low CRC byte first.
For `123456789` the result is 0x6f91; an empty payload requires ff ff.

DT 0x00/01/02/03 are FS/FE/LS/LE. DT 0x08..0x0f are generic short packets:
their 16-bit data is passed through and they impose no frame/line order rules.
Reserved short DT 0x04..0x07 is explicitly rejected. Short packets carry no
payload and no payload CRC. When `cfg_check_sequence=1`, separate VC state
rejects duplicate FS, FE without FS, FE with an open line, LS outside a frame
or with an open line, LE outside an open line, mismatched FS/FE frame numbers,
and mismatched LS/LE line numbers. Optional line packets are supported; no
monotonic-number policy is imposed. Sequence checks do not force long packets
to be inside a frame and do not force all frames to be closed at session end.
With checks disabled, events still update state but are not rejected for order.
Each new session clears this state, so a session which enables checks must
contain the FS/LS events needed by subsequent FE/LE events in that session.

## Reports, errors and recovery

Every consumed packet, including a malformed/truncated packet, has one held
`p_valid/p_ready` report. It carries VC/DT/WC/short/corrected metadata,
`p_header_valid`, `p_payload_bytes`, calculated/received CRC, `p_last`,
`p_error`, and `p_error_code`. `p_header_valid` means the header passed ECC;
it can be one for capacity or reserved-short rejection even though no header
stream token was emitted. When zero, metadata is cleared and must be ignored.
Payload count includes bytes accepted at the input; abort can cancel a final
pending output byte. For a dispatched long header the calculated CRC starts
at 0xffff and follows accepted payload bytes. Received CRC fields contain only
the CRC bytes actually consumed. CRC fields are zero for short/undispatched
headers. `p_last` marks a normal end-of-session packet or a fatal packet.

| Code | Meaning | Policy |
|---|---|---|
| 01 | Illegal static MAX_WORD_COUNT | Direct failed DONE, no packet report |
| 02 | Uncorrectable protected header ECC | Fatal report, stop session |
| 03 | Reserved ECC bits nonzero | Fatal report, stop session |
| 04 | `s_last` before complete header/payload/two CRC bytes | Fatal report |
| 05 | Long WC exceeds MAX_WORD_COUNT | Fatal report, no payload |
| 06 | Reserved short DT | Fatal report |
| 07 | Enabled per-VC short-packet sequence check failed | Fatal report |
| 08 | Payload CRC mismatch | Failed packet report; continue at trusted WC boundary |
| 09 | Abort | Fatal report, except committed-report behavior below |

After a CRC mismatch, following packets are still parsed because the corrected
word count gives a trusted boundary. The session eventually has failed DONE.
All header/sequence/length errors stop rather than guessing a new header boundary.
After acknowledging `done_valid`, a new command can run without global reset,
including after errors. The source must discard unconsumed bytes from the failed
session before supplying a new session. `done_error/error_code` reports the first
session error; per-packet errors retain their individual causes.

Abort has priority over header/payload work on a CE-enabled edge. It cancels
any outstanding header/payload token, ending their stability contract. Consumers
which share abort must ignore transfers on that accepted abort edge. An abort
while CE=0 does not change registered state. A report is already committed:
its fields are immutable. During a nonfinal report, an abort is latched even
under report backpressure and causes failed DONE after report acknowledgment,
without inventing another packet. Once a final/fatal report or DONE is visible,
late aborts are ignored. DONE remains held until acknowledged. Terminal records
therefore cannot be rewritten by a late abort.

Counters are per-session 32-bit saturating `packet_count` (acknowledged reports),
`corrected_count` (ECC-corrected headers), and `crc_error_count`. `frame_active`
and `line_active` expose one bit per VC. `MAX_WORD_COUNT` is legal in 0..65535,
defaults to 4096, and bounds accepted long-packet lengths without allocating RAM.

## Reproducible validation

Run from repository root:

```powershell
python -B cores/system/common_scaffold/image/csi2_packet_rx/run_tests.py
python -B cores/system/common_scaffold/image/csi2_packet_rx/test_protocol.py
python -B cores/system/common_scaffold/image/csi2_packet_rx/test_numeric.py
python -B cores/system/common_scaffold/image/csi2_packet_rx/synth.py
```

The Python oracle constructs standard parity equations from explicit bit sets;
its CRC uses the mature `binascii.crc_hqx` C engine with independently reflected
input/output. It generates actual header/payload/CRC wire bytes and checks every
RTL header token, payload byte/marker and terminal report. The main regression
has 2705 sessions/2963 packet reports/26765 payload bytes: all 30 protected
single-bit positions and all 435 protected double-bit pairs on each of four VCs;
two reserved singles and every pair involving reserved bits; every bit in a
32-byte payload and its CRC; all long DTs; generic/reserved shorts; zero-length
packets; every truncation position; 4096/4097 WC; interleaved four-VC FS/LS/LE/FE;
sequence/number errors; CRC-error continuation; and 200 contiguous mixed packets.
All token holds, CE gaps, source gaps, and sink backpressure are checked.

Protocol tests abort 12 parser/report phases, reset 13 phases with CE disabled,
and decode 26 healthy recovery sessions. They explicitly exercise a pulse of
abort under blocked nonfinal report, immutable final report/DONE, and idle abort.
Numeric tests consume a complete 65535-byte packet, zero-capacity legal packets,
capacity rejection, and explicit errors for static limits -1 and 65536.

All four commands pass on the frozen RTL. Isolated Gowin synthesis reports
1077 LUT-class cells for default WC=4096, 1059 for WC=65535, and 1084 for
WC=0; every profile uses zero DSP and zero block RAM. The small per-VC control
arrays synthesize to registers, and payload holding is one byte.

The source-bound JSON/logs record exact results. Synthesis covers default,
zero-capacity and maximum-WC profiles; LUT-class includes LUT+ALU+MUX+4*RAM16SDP4,
and every block RAM primitive counts as two BRAM9 units. No routed timing,
camera/D-PHY, physical-board or throughput acceptance is claimed. Simulation
binaries/vectors and reference downloads use automatically removed temporary
directories; only small reproducible evidence is retained.
