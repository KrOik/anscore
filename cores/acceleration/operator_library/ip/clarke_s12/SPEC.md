# clarke_s12

Three-shunt Clarke transform, amplitude-invariant, one beat, stateless. Currents are signed 10-bit counts: ia=a[9:0], ib=a[19:10], ic=b[9:0]; a[31:20], b[31:10] and c[30:8] must be zero (malformed beat: result=aux=0, fault=1, no state). alpha=ia and beta=(ia+2*ib)/sqrt3, both returned as signed 12-bit counts (Q10, +/-1.0 = +/-1024). beta is one MULT12X12 product of (ia+2*ib) by the fixed slice round(2^11/sqrt3)=1182 requantised by >>>11 with round-half-up. A second slice evaluates the same beta from the other phase pair, beta2=(ib-ic)/sqrt3, which is algebraically identical when ia+ib+ic=0, so their difference is exactly the zero-sequence current divided by sqrt3: c[31]=1 enables the sensor-plausibility check and c[7:0]=tolerance T in beta counts raises fault when |beta-beta2| > T (result and aux stay valid). result[11:0]=alpha, result[23:12]=beta, result[31:24]=0. aux[11:0]=beta2, aux[23:12]=|beta-beta2| truncated to 12 bits, aux[24]=check enabled, aux[25]=check violated, aux[31:26]=0.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 1. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: A CPU Clarke is three loads, a shift and a multiply with a branch on the shunt sign; this retires alpha, beta and an independent sensor-consistency residual in one enabled beat, so a broken current shunt is caught inside the same PWM period that would damage it.

Independent integer model: `step("clarke_s12", a, b, c, state)` in tools/fam_motor.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 126 distinct responses, 9 fault rows.
