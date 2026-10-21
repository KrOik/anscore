# ctl_phase_nco32

Direct digital synthesis phase step. state[31:0]=phase P, state[39:32]=W, a saturating count of wrap events. a[31:0]=tuning word (also the reload value). b[15:0]=signed two-complement phase dither, b[16]=1 steps P downwards, b[31:17] must be zero. c[31]=1 reloads P:=a and W:=0 and emits no step, c[30:0] must be zero. Otherwise P := (P + (b[16] ? -a : a) + dither) mod 2^32, free running with no overflow fault, and W := min(W + wrap events, 255) where each crossing of a 2^32 boundary is one event, up to two per beat. result=new P. aux[1:0]=quadrant P[31:30], aux[2]=wrapped upward, aux[3]=wrapped below zero, aux[4]=W saturated, aux[15:8]=W, aux[16]=reload applied. Any non-zero reserved bit is a malformed control word: f=1, the beat is rejected with P and W held, result=held P and aux[1:0] plus aux[15:8] echo the held quadrant and count. event_counter and token_bucket in the sibling library add a word to a scalar budget; this is a 32-bit signed-dither accumulator reporting quadrant and carry count in the same beat.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 1. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: A DDS or stepper axis must add a 32-bit tuning word, a signed dither and a wrap count every reference cycle; a software loop pays a branch and a multi-word fixup per step and jitters, this emits phase plus quadrant at II=1.

Independent integer model: `step("ctl_phase_nco32", a, b, c, state)` in tools/fam_control.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 112 distinct responses, 16 fault rows.
