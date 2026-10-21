# crc8_poly07_byte

CRC update: state a[7:0], byte b[7:0], MSB-first, polynomial 0x07; no initial/final xor.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("crc8_poly07_byte", a, b, c, state)`. Test vectors: 342. No additional RTL dependencies.
