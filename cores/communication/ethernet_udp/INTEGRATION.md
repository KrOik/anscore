#25K controlled-replay binding

`examples/25k/udp_top.v` connects unchanged shared UART/CSR transport to
`udp_control`, which owns the actual internal UDP/RMII replay. Clock50MHz E2,
TX C3, RX B3, LVCMOS33. Probe CH0..7 use G5,F5,G8,G7,H7,H8,J5,H5. The
top is for Primer25K, not the currently confirmed20K. No real PHY pins are
bound: RMII TX/RX are connected internally for controlled replay.

```
. ./scripts/env.ps1
python cores/communication/ethernet_udp/tools/test_uart.py
python cores/communication/ethernet_udp/tools/build_board.py
```

UART simulation uses8core clocks/bit and real serial input/output. It verifies
two numerical replay results, queued configuration, identity, invalid command
and explicit ACK. Partial byte strobes/CSR response stalls are exercised in
test_control.py, since the wire transport supplies full-word writes.
Physical UART default434clocks/bit is approximately115200baud at50MHz.

The build freezes all RTL/constraints and a64-bit fingerprint, maps to
GW5A-LV25MG121NES, requests50MHz routing and packs SRAM output. Distributed
RAM and wide LUT mapping are disabled for device mapping compatibility.
All core/control features are retained. The build never downloads. Its
artifact status and P&R report are authoritative; a running build is not a
successful PPA result. Pin timing/voltage and oscillator accuracy still need
actual target verification.

`tools/udp_host.py` is transport neutral: `bus.access(address,optional_word)`
must perform bounded operations and raise on transport/CSR errors. It validates
configuration/loaded identity, writes shadow words, commits once, polls within
bounds, saves full result and checks cycles/counters/CRC/version/coherence
before ACK. It never retries writes or ACKs a failed verification. The normal
acceptance profile is limited to16MiB per run for host reference generation;
this host limit does not change the RTL packet count/length contract.

`python cores/communication/ethernet_udp/tools/test_host.py` obtains actual numeric
CSR fixture words by running test_control.py, then exercises host acceptance
and ten corruption/identity/timeout guards. This is not a physical UART/JTAG
test. The supplementary board runner validates a completed50MHz25K build,
packed-image/current-source hashes and the actual loaded CSR fingerprint:

```
python cores/communication/ethernet_udp/tools/run_uart.py --port COMx --build-summary artifacts/ethernet_udp_25k/board_TIMESTAMP/summary.json --output artifacts/ethernet_udp_25k/physical_UNIQUE
```

It requires an already loaded matching25K image and working UART wiring.
Three finite profiles exercise16x37,8x1472 and32x4payload bytes. Partial
captures, host hashes and raw UART exchanges are saved even on failure.
It does not program hardware or verify an external PHY. Hard-user-JTAG
runtime remains a mandatory separate gate.

Remaining physical acceptance: matching25K SRAM configuration, verified
hard-JTAG runtime/readback, complete numeric replay/error results and LA
event captures. No current simulation or internal RMII loop establishes a
real100Mbps external PHY link.
