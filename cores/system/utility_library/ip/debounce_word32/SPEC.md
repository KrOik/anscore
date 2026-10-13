# debounce_word32

a=candidate word,b=number of identical accepted samples (1..65535),c[31]=restart. result=stable word,aux=current run length capped at65535. Invalid b faults and preserves state. Reset stable=0; qualified candidate replaces stable.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("debounce_word32", a, b, c, state)`. Test vectors: 357. No additional RTL dependencies.
