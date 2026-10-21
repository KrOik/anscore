# Lock-in control register contract

`lockin_control` uses the existing transport-neutral request/response interface:
8-bit byte address, 32-bit data, four byte strobes, valid/ready. One outstanding
request; response data/error remain stable under backpressure. Unaligned,
undefined or disallowed accesses return an error without performing the action.
Reset clears configuration, measurement state and timestamp epoch.

| Address | Access | Meaning |
|---|---|---|
| 00 | R | Magic `4c4f434b` |
| 04 | R | bit0 ready, bit1 result held, bit2 pending commit, bit3 commit ready, bit4 unaccepted command |
| 08 | R | Applied configuration version |
| 0c | W | Commit and schedule exactly one run; full strobes, value 1 |
| 10 | W | Acknowledge held result; full strobes, value 1 |
| 14,18 | R | Build ID low/high words |
| 40..7c | RW | Write shadow configuration; read active configuration |
| 80 | R | Result command ID |
| 84 | R | Replay error bits (see REPLAY.md) |
| 88 | R | Run clocks |
| 8c,90,94 | R | Generated, accepted, dropped sample vectors |
| 98,9c | R | First timestamp low/high |
| a0,a4 | R | Last timestamp low/high |
| b0+12*n | R | Lane n signed I in bits15:0, signed Q in bits31:16 |
| b4+12*n | R | Lane n unsigned amplitude |
| b8+12*n | R | Lane n signed phase radians times16384, sign extended |

Lane n is 0..3. Result reads require a held result, including error runs.
Result registers remain coherent until explicit acknowledgement; reads do not
clear them. Acknowledgement consumes them, so later result reads fail until
another completion. No automatic retries or acknowledgement occur.

Configuration word index `(address-0x40)/4`:

| Words | Meaning |
|---|---|
| 0 | DDS tuning word |
| 1 | Sample period in core clocks, minimum4 |
| 2 | log2 sample count in low4 bits, valid4..12; other bits ignored |
| 3 | Command ID |
| 4 | Timeout in core clocks; zero returns timeout without launch |
| 5,6 | Four unsigned16 source amplitudes, low lane first |
| 7 | Four byte source phase indices, low lane first |
| 8,9 | Four signed16 calibration offsets |
| 10,11 | Four unsigned16 Q1.15 calibration gains |
| 12 | bit0 blocks sample acceptance for fault injection; other bits ignored |
| 13..15 | Reserved storage, no operational effect; write zero |

Shadow writes honor byte strobes. One pending commit is supported. Writes or
commits while a commit is pending fail. Active configuration remains frozen
while running or holding a result. A queued commit applies after result ACK;
its version increment produces exactly one subsequent command. Reading active
configuration during a queued commit returns the previous operation's values.

Validation: `python cores/signal_processing/lockin/tools/test_control.py` after loading
`scripts/env.ps1`. Real ADC/lock-in RTL, CSR traffic with response stalls,
queued configurations, exact independent IQ, amplitude/phase tolerances,
timestamp span/continuity, timeout data, invalid accesses and ACK are tested.
This is digital simulation; board UART/JTAG and physical timing remain open.
