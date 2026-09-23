# park_s12

Park transform (alpha,beta -> d,q) by the three-multiplier Gauss trick, one beat, stateless. alpha=a[11:0] and beta=b[11:0] are signed Q10 counts with +/-1.0 = +/-1024; each is saturated into the rotation domain [-1024,1023] and the saturation is reported (aux[8], aux[9]). theta=c[7:0] indexes the generated 256-entry Q10 sin/cos image (word k = (cos12<<12)|sin12 at 360*k/256 degrees, unity = 1024); c[30:8] must be zero (malformed beat: result=aux=0, fault=1). Products are m1=alpha*cos, m2=beta*(-sin), m3=(alpha+beta)*(cos-sin), so d=round_up((m1-m2)>>>10) and q=round_up((m3-m1-m2)>>>10); the sums are exact because |alpha+beta|<=2047 and |cos|+|sin|<=1448 both fit the 12-bit signed slice input, which is why the bus is 11-bit full scale and the table Q10. result[11:0]=d, result[23:12]=q, result[31:24]=0. aux[7:0]=theta, aux[8]=alpha saturated, aux[9]=beta saturated, aux[10]=|d| above the 11-bit regulator range, aux[11]=|q| above it, aux[31:12]=0. fault=1 only on a malformed control word: a 12-bit output bus absorbs any in-range rotation.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 1. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: d and q are the two quantities every current loop needs, and they need three products: three slices plus a shift tree close the transform in one enabled beat instead of the four multiplies and two fix-ups a CPU scheduler needs at the PWM rate.

Independent integer model: `step("park_s12", a, b, c, state)` in tools/fam_motor.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 126 distinct responses, 3 fault rows.
