# hamming13_encode8

SECDED code: 8 data bits a[7:0] in positions 3,5,6,7,9,10,11,12; even parity at 1,2,4,8; overall parity at 13. Position 1 is result bit0.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("hamming13_encode8", a, b, c, state)`. Test vectors: 342. No additional RTL dependencies.
