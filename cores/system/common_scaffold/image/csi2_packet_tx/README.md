# CSI-2 byte packet transmitter

Synthesizable original RTL for legacy 2-bit VC CSI-2 packets. This is the missing transmit counterpart to the existing byte packet receiver. Repository search for CSI-2 TX/transmitter paths found no existing implementation. No D-PHY, lane striping, clocks, extended VC, camera timing generator or packet scheduling is included.

## Interface and transaction

`csi2_packet_tx` ports: `clk,rst_n,ce,start_valid,start_ready,cfg_vc[1:0],cfg_dt[5:0],cfg_word_count[15:0],abort,s_data[7:0],s_valid,s_last,s_ready,m_data[7:0],m_valid,m_ready,m_sof,m_last,done_valid,done_ready,done_error,error_code[7:0],busy,output_bytes[31:0]`.

Every ordinary transfer requires CE and ready/valid. Reset is synchronous, active low, and takes priority over CE. Config is captured on the accepted start; changing it while busy cannot change the current packet. Start is accepted only in IDLE; DONE remains held until a CE-qualified done_ready acknowledgement, then a new transaction may start. `busy` includes DONE. Deasserted CE freezes internal state and all visible output tokens. The consumer must qualify its handshakes with CE as well.

Data ID is `{VC,DT}` followed by little-endian word count/data and 6-bit header ECC (upper ECC bits zero). DT 00..03 are FS/FE/LS/LE, DT 08..0f generic short packets: cfg_word_count is the 16-bit short data field, no payload accepted, exactly 4 output bytes. Reserved short DT 04..07 reports error 1 without output. DT 10..3f are long packets; arbitrary payload bytes are transported without interpreting their pixel format. Exactly WC payload bytes are followed by reflected CRC16 (poly 0x8408, initial FFFF, no final xor), low byte first. WC=0 generates a header and FFFF CRC; WC=65535 is supported. Byte count fits 65541.

`s_last` must be true exactly for the WC-th accepted payload byte. Early or missing last reports error 2 before forwarding the offending byte. Further bytes outside s_ready are not accepted and are not considered an extra byte of this packet. There is no padding or input timeout: absent input waits indefinitely for a valid byte or abort/reset. `m_sof` identifies byte 0; `m_last` identifies the ECC of a short packet or final CRC byte of a long packet. Output bytes and both markers hold under backpressure. Payload uses a single-byte registered buffer and has a maximum rate of one byte per two CE-qualified cycles; header and CRC can emit one byte per cycle.

All output bytes are **provisional until successful DONE**. On malformed input, reset or abort the consumer must discard the entire packet, including any already transferred bytes. No rollback storage is included. Abort is CE-qualified, has priority over normal handshakes, cancels the current transfer boundary and enters held DONE/error 3. An abort cycle is a cancellation boundary and must not be counted as a committed input/output transfer; output_bytes counts prior ordinary transfers. Abort is ignored in IDLE and DONE. Reset clears everything, including counters. Normal output_bytes counts emitted header/payload/CRC bytes, not submitted bytes. No security or physical interface validation is claimed.

## Verification

Run from repository root:

```
python -B cores/system/common_scaffold/image/csi2_packet_tx/run_tests.py
python -B cores/system/common_scaffold/image/csi2_packet_tx/test_protocol.py
python -B cores/system/common_scaffold/image/csi2_packet_tx/synth.py
```

Main regression: 260 packets, all 64 DT values across all four VCs, random 16-bit short data, long WC 0/1/4096/65535, 73168 output bytes. Every output byte/marker is compared with an independent Python header matrix and binascii CCITT engine with bit reversal; known CRC `123456789 = 6f91`. No RX oracle imports are used. CE gaps, byte backpressure, configuration mutation, held DONE are exercised. Protocol regression: all five active FSM states aborted and reset with CE low, early/missing last, starvation, idle/DONE abort, DONE reset and healthy recovery (24 held reports). These are offline simulations, not a board or routed timing claim.

Gowin isolated synthesis with `-nodsp; check -assert`: 256 LUT-class, 0 DSP, 0 conservative BRAM9. Resource sum includes LUT/ALU/MUX and four times RAM16SDP4; every block memory primitive would count as two BRAM9. No block memory is instantiated.

References are actually retrieved pinned sources; see references.json for URLs, SHA256, time and excerpts, and fetch_references.py to repeat. Linux sun6i DSI shares the mathematical ECC/CRC convention but is not evidence of CSI-2 D-PHY support. Original RTL is not copied third-party source. All generated simulators, test vectors and downloaded source files live in TemporaryDirectory and are removed; persisted logs/evidence are retained.
