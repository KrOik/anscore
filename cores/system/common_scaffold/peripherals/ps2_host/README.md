# PS/2 open-collector host

Independent synthesizable keyboard/mouse byte transport. No keyboard key-map, mouse packet interpretation or automatic command retry is implied. External pull-ups, voltage compatibility and board IO tri-state buffers are integration responsibilities. Only `*_drive_low` enables are generated; never actively drive high.

`ce` gates host handshakes and abort, while filters, RX, physical TX timing and timeouts run every clock. RX continues while TX completion is held, including CE=0, so unsolicited device replies are retained. FIFO storage has RX_FIFO_DEPTH entries plus one held output byte. Accepted output bytes survive abort and all backpressure. At a full ring, a coincident fetch still conservatively rejects the new byte and reports overflow: no device-dependent same-address RAM collision semantics. Overflow drops only the new byte, increments both counters, and leaves existing data intact.

TX captures its byte on ce/valid/ready, qualifies idle, inhibits clock (default100us), holds request (default10us), sends eight LSB-first bits plus odd parity and stop, checks rising-edge wired-AND consistency including stop, checks device ACK, and waits for line release. Incoming RX has arbitration priority. Done/error remains valid until ce/ready. RX validates start, parity, stop and inter-edge timeout. First unacknowledged RX error stays stable; every subsequent error increments rx_error_count. Counters wrap modulo2^32.

Errors:1 invalid parameter;2 RX parity;3 RX stop;4 RX overflow;5 TX NACK;6 edge/release timeout;7 TX bus collision;9 abort. Reset releases both pins regardless CE. Abort preserves completed RX bytes and releases active TX immediately when CE=1.

Parameters: CLK_HZ1MHz..250MHz; FILTER_CYCLES1..32; RX_FIFO_DEPTH2..256; INHIBIT_CYCLES4..25000000; REQUEST_CYCLES2..2500000; EDGE_TIMEOUT_CYCLES16..25000000; IDLE_CYCLES2..2500000. Custom cycle values must respect device electrical timings and filtering. Defaults assume ordinary PS/2 device timing. Device must provide a real high phase after host clock release.

Run from repository root:

    python -B cores/system/common_scaffold/peripherals/ps2_host/run_tests.py
    python -B cores/system/common_scaffold/peripherals/ps2_host/test_protocol.py
    python -B cores/system/common_scaffold/peripherals/ps2_host/test_numeric_limits.py
    python -B cores/system/common_scaffold/peripherals/ps2_host/test_parameters.py
    python -B cores/system/common_scaffold/peripherals/ps2_host/synth.py

All PASS: main268RX+264TX includes every byte in each direction; protocol46checks covers CE-off reception, reply under held TX done, stop contention, parity/stop/filter, FIFO overflow, timeout, arbitration, all active-state abort and reset; four legal parameter profiles and fourteen invalid profiles. Independent wired-AND device waveform checks rising-edge TX/parity/stop and physical pulse widths. Simulations use C: temporary directories automatically removed. Synthesis default depth16:817 LUT-class/0DSP/0BRAM9; max depth256:797/0/2. LUT-class includes ALU/MUX and4xdistributed RAM. No board programming or board-level electrical validation performed.
