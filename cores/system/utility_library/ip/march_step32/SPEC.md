# march_step32

a=observed word,b=phase0..5,c=address. March C- micro-step: w0,r0w1,r1w0,r0w1,r1w0,r0. result=write data; aux[0]=write,aux[1]=compare,aux[2]=descending,aux[31:3]=c low29. Compare mismatch faults; this is a micro-step, not a RAM controller.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Independent model: `step("march_step32", a, b, c, state)`. Test vectors: 342. No additional RTL dependencies.
