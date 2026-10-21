# User-scan CSR mailbox (simulation-qualified, physical integration pending)

`rtl/scan_csr_mailbox.v` is an independent scan-register transport, not a TAP
controller and not a replacement for the FPGA hard JTAG port. A device wrapper
must supply selected/capture/shift/update/TDI from a supported user instruction
and route TDO back through the hard primitive. No such wrapper or physical host
backend is delivered yet. No pin-level user-JTAG acceptance is claimed.

## Wire format

The DR is exactly 72 bits, shifted least-significant bit first. All controls
are synchronous to rising TCK and mutually exclusive, with capture before
shift and one update after the full frame. TDO presents the current LSB before
each shift edge. Device-specific edge adaptation must be checked when binding
the actual primitive. Leaving selected clears the frame bit counter.

| Command bits | Meaning |
|---|---|
| 71:64 | CRC8 polynomial 0x07, initial zero, over payload bytes low to high |
| 63:56 | 0xA5 |
| 55:48 | host transaction tag |
| 47 | write=1/read=0 |
| 46:43 | byte strobes |
| 42:35 | byte address |
| 34:3 | 32-bit data |
| 2:0 | zero |

A full 72-bit zero frame is NOP/poll. It does not issue a CSR request or clear
errors. All other bad lengths, CRC, magic or reserved bits are rejected before
CSR. New commands while busy are rejected without overwriting the in-flight
request. A successful command clears the sticky command-error flag.

| Response bits | Meaning |
|---|---|
| 71:64 | same CRC8 rule |
| 63:56 | 0x5A |
| 55:48 | last completed tag |
| 47:44 | zero |
| 43 | sticky rejected-command flag |
| 42 | last response CSR error |
| 41 | completed response available |
| 40 | outstanding request busy |
| 39:8 | CSR result |
| 7:0 | protocol version 1 |

Capture snapshots a whole response frame; completion during shifting cannot
change that frame. The last completed response persists across NOPs. After a
new command, poll until busy=0, valid=1 and tag matches; elapsed scan clocks
alone are not a completion condition. Reusing a tag after 256 completed
transactions is allowed. A lost response should be polled, not blindly retried:
the mailbox does not implement a duplicate-request cache. CRC detects transfer
errors; it is not authentication or a security claim.

`tools/scan_protocol.py` implements the host wire codec. It returns nine bytes
in little-endian shift order. It performs no USB/JTAG I/O. The test runner
cross-checks RTL request/response vectors against this independent codec.

## CDC and reset contract

Only one transaction is outstanding. The TCK-domain payload is held while a
request toggle passes two system-clock synchronizers. The system captures the
payload, holds CSR valid/data until ready, then waits for response valid. A
response and tag are held before an acknowledgement toggle crosses back;
the TCK domain copies them into a separate snapshot after synchronization.
No combinational CSR response or unsynchronized response bus drives scan data.

Reset is a shared active-low asynchronous assertion with separate two-edge
release synchronizers in each domain. Independent domain resets are unsupported.
Reset aborts pending and accepted transactions; system reset must also reset
the CSR endpoint/DUT. RAM contents in the test shell are not cleared. Initial
commands require both release sequences to finish. There is no mailbox
watchdog or cancellation of an accepted CSR side effect; a backend that never
responds holds busy until common reset. Host software needs a deadline.

The toggle synchronizers carry ASYNC_REG attributes. The held multi-bit buses
still require placement/timing constraints at integration: constrain their
settling paths before the destination sampling edge, identify the real TCK
clock, and constrain synchronizer paths appropriately. Asynchronous simulation
does not prove metastability MTBF or physical CDC safety. No blanket false-path
constraint or physical timing qualification is supplied here.

## Current evidence

Command: `. ./scripts/env.ps1`, then
`python cores/system/ip_test_shell/tools/test_scan_mailbox.py`.

`artifacts/ip_test_shell_25k/scan_20261020T155253230058Z` passes 52 complete
transactions at each TCK period 6/14/46 ns against a 10 ns system clock,
including corruption/length/magic/reserved rejects, busy overwrite prevention,
CSR stalls/errors, stable mid-shift snapshots, NOP and reset abort/recovery.
One additional backend-accepted transaction per ratio is deliberately reset
before response. A separate end-to-end test sends serial scan bits through the
mailbox into the real CSR/packet fabric: three datasets, 290 complete words,
no reset between datasets, independent Python golden and CRC verification.

Isolated GW5A synthesis passes: 482 LUT1..4, 14 ALU, 276 FF, 0 DSP/BSRAM.
Evidence: scan_synth_20261020T235155755. This is synthesis only: no P&R, Fmax,
device primitive binding, hardware mailbox or 25K L3 gate is proven.

## Host transaction driver

`tools/scan_bus.py` supplies an abstract ScanCsr bus with access(address,data=None,
strobe=15). Its supplied exchange callback must perform Capture/72-bit LSB-first
Shift/Update through the actual hard user instruction. No physical backend is
provided. It polls idle,selects a fresh tag relative to the observed last tag,
ignores the old Capture response to a submitted command,then waits for matching
valid/nonbusy completion. CRC/rejection/timeout after submission poisons the
session; writes are never automatically retried. Target CSR errors are known
completions and do not poison it. Polls are bounded by both time and count.

Command: python cores/system/ip_test_shell/tools/test_scan_bus.py
Evidence scan_bus_20261020T184825730157Z PASS:261 transactions,tag wrap,
delayed/stale response,packing,CSR errors,CRC/rejected-command/timeout,
no duplicate write after uncertain completion,invalid fields/poll bounds.
These are software fixtures,not physical hard-JTAG acceptance.
