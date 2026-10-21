# Host-loaded stimulus and response storage

`rtl/csr_capture_replay.v` instantiates the unchanged canonical
`cores/system/stream_bus_library/rtl/sys_capture_replay.v`. It exposes a
separate byte-addressed CSR aperture, now decoded at 0x40..0x64 by
`ip_test_shell_core`. It is not connected to physical hard JTAG. It is distinct from
the existing generated four-source runner. No physical acceptance is claimed.

Single clock, asynchronous active-low control reset, synchronous RAM. Default
DEPTH=256, power of two, 2..32768. Data is opaque 32-bit words, with no implicit
keep/last/user encoding. A stream integration must specify its own packing.
RAM contents are not reset; the host must load every referenced stimulus word
after reset. Response reads are permitted only when inactive and below captured.

| Byte offset | Access | Meaning |
|---|---|---|
| 0x00 | R/W | status bits busy/done/error in bits 0/1/2; write exactly 1 to launch |
| 0x04 | R/W | input word count, 16-bit |
| 0x08 | R/W | output word count, 16-bit |
| 0x0c | R/W | stimulus index, no auto increment |
| 0x10 | W | stimulus word at selected index |
| 0x14 | R/W | response index, no auto increment |
| 0x18 | R | synchronous response RAM word |
| 0x1c | R | elapsed active cycles |
| 0x20 | R | accepted input words |
| 0x24 | R | captured output words |

All accesses must be aligned. Writes require all four byte strobes and inactive
status, including start and index changes. Unsupported addresses, out-of-range
indices, active-run reads of response RAM, and partial writes return error
without mutation. Lengths 0 or greater than DEPTH can be programmed but launch
terminates with done/error, never replaying out-of-range RAM. TIMEOUT=0 disables
the timeout. Error/done remain until the next launch or reset. Reset aborts.

Requests use valid/ready; responses remain stable under backpressure. A response
index write adds one wait cycle before acknowledging, allowing an immediately
following RAM read to see the new index even with pipelined CSR requests.
Data/valid remain stable while the stream stalls. The canonical RAM pipeline
supports one accepted input and output word per cycle after initial fetch when
the connected consumer/producer is ready; external system throughput must be
measured separately. The watchdog is a terminal abort and deasserts valid.

Regression: `. ./scripts/env.ps1`, then
`python cores/system/ip_test_shell/tools/test_components.py`.
Evidence `artifacts/ip_test_shell_25k/components_20261020T152714530662Z` includes
three independently loaded datasets, 24 complete transformed response words,
stream/CSR stalls, busy guards, invalid lengths/indices/strobes, timeout and
reset recovery. Response golden is `(0x10203040 + run*1009 + index*73) XOR
0x5a39c617`, evaluated by the testbench independently of stored response data.

Isolated GW5A synthesis passed with 296 LUT1..4, 216 ALU, 199 FF, 2 SDPX9B,
0 DSP. SDPX9B is a synthesis-cell count, not a routed physical block count.
That isolated result has no P&R, Fmax or board qualification.
Evidence: `artifacts/ip_test_shell_25k/capture_synth_20261020T232748210`.

## Integrated loaded packet path

`loaded_fabric_replay.v` connects stimulus words to source 0 of the actual
four-source packet switch, 32->24 adapter and packet FIFO, then a 24->32
adapter returns full words to response RAM. Sources 1..3 are idle in this mode.
Each word is one packet with keep=0xf, last=1 and user=0; restored output
metadata is checked in simulation. This mode does not load arbitrary packet
lengths or all four sources. The original generated mode still exercises four
sources with variable packet lengths.

The consumer stalls four cycles per 16 active cycles. The stream pipeline
resets between runs and after timeout. Both fabric clock ports use clk here;
this is not an independent-clock reset-release CDC proof. Generated and loaded
runners have separate storage and status.

Write 0x08=2 to select the loaded-path probe page. CH0..7 are registered
`active, s_valid, fabric_out_valid, fabric_out_ready, repacked_valid,
response_ready_with_stalls, repacked_last, error`, one clock observation delay.
Other page meanings remain those of the generated runner; pages 4..7 blank.

Integrated evidence: replay_20261020T154344672941Z. Three loaded datasets of
3,31,256 words pass complete readback with separate Python golden and CRC;
generated mode retains all three prior CRCs and 440 complete trace words. CSR
response selection remains stable when request addresses change under response
backpressure. No reset between these six runs. Physical acceptance remains open.
