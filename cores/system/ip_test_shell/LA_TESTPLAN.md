# IP-04 LA test plan and measured status

Verified current CH0..7 pins: G5,F5,G8,G7,H7,H8,J5,H5. Bidirectional
frequency-signature evidence: tang25k_la_calibration_20261020T151850219242Z.
Previous A10/A11/E10/E11/L11/K11/K5/L5 wiring is historical.
FX2 firmware 1.4; measured 8-channel rate 2MS/s. USB ID does not establish
maximum input voltage or threshold ratings; those remain to be identified.

## Isolated UART diagnostic page

| CH | Signal | Observation |
|---|---|---|
| 0 | B3 UART RX | one-clock registered pin sample |
| 1 | C3 UART TX | one-clock registered pin sample |
| 2 | received-byte event toggle | toggles once per decoded byte |
| 3 | framing-error sticky | cleared on reset |
| 4 | last RX data bit0 | held between receive events |
| 5 | transmitted-byte event toggle | toggles once per beacon |
| 6 | clock ticks bit18 | periodic heartbeat |
| 7 | reset released | high after POR |

Trigger is host-pattern transmission after capture has started; raw acquisition
is free-running, not a hardware edge trigger. Each capture records sample rate,
clock, bitstream hash, exact host bytes, decoded bytes, and all channel counts.
Registered pin observation adds 20ns at 50MHz; samples are 500ns apart.

First valid capture: `artifacts/ip_test_shell_25k/uart_la_20261020T150700456410Z`.
1 second / 2000000 samples, no USB capture errors, 95 decoded TX frames all 0x55;
D2XX host received eight 0x55 bytes. RX stayed high in that window with no RX
event. Exported `waveform.png` shows actual samples and measurement settings.
This proves that configuration's FPGA-to-host UART path. It does not establish
why the host-to-FPGA signal was absent.

User confirms the connection is made. A subsequent GPIO-mode diagnostic hung
inside D2XX and the device enumerated abnormally. The process was stopped; USB
re-enumeration restored UART/JTAG. That diagnostic is now disabled in software.
Its raw capture is retained at uart_la_20261020T150926404047Z but is invalid
for FPGA pin conclusions (all channels high; no complete host-call report).

After recovery, uart_la_20261020T151507596874Z again received host beacon bytes,
but all eight LA channels were high, including expected periodic/low signals.
That probe capture is invalid for RX or timing conclusions. The user subsequently
confirmed changed wiring; new constraints and calibration restore valid signals.
Latest valid capture: uart_la_20261020T152118136448Z, 2MS/s, 2000000 samples.
TX decoded 95 frames, all 0x55; host received eight 0x55 bytes. RX stayed high
while host sent a500000000000069, and no receive events occurred. Cause remains
unproven. All eight new probe mappings pass forward/reverse signatures.

## Remaining acceptance

- Trustworthy simultaneous LA signals recovered; UART RX command arrival remains open.
- Run same-image three-case data readback through the physical control channel.
- Capture stream valid/ready stall and recovery with zero error.
- Bind both load classes to build hash/run IDs, full golden and raw trace files.
- Runtime hard JTAG stimulus loading remains distinct from UART control and is open.
