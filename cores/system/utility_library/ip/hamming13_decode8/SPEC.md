# hamming13_decode8

Decode low13 a. aux[0]=corrected, aux[1]=uncorrectable, aux[7:4]=syndrome. Double errors, impossible syndrome, or high input bits fault; result=0 on fault. No claim for >=3 flips.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("hamming13_decode8", a, b, c, state)`. Test vectors: 802. No additional RTL dependencies.
