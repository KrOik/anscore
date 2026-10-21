# UART CSR transport v1

115200 baud, 8N1. Host waits for the complete reply before sending another
request. This is separate from runtime hard JTAG.

Request (8 bytes): `A5 op address data0 data1 data2 data3 crc8`.
op 0 reads, op 1 writes all four bytes. Data is little endian.
Reply: `5A status address data0 data1 data2 data3 crc8`.
Status 0 is success, 1 is CSR error. CRC8 starts at 0, polynomial 0x07,
MSB first over the first seven bytes, no final XOR.

Bad CRC and unknown op are discarded without execution. UART framing error or
a 100000-clock inter-byte gap discards a partial request. Input arriving during
another command/reply is not queued. There are no retry sequence numbers or
exactly-once guarantees; do not automatically retry start after ambiguous failure.

The D2XX runner verifies source/bitstream hashes, optionally programs SRAM once,
then requests three runtime cases and complete trace readback. It records raw
request/reply bytes on failure. Current physical attempt received no ID reply.
