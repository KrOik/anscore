# inv_park_s12

Inverse Park transform (d,q -> alpha,beta), the exact complement of park_s12: same generated Q10 sin/cos image, same saturation rule, same three-multiplier Gauss form with the sign of the cross term flipped. d=a[11:0], q=b[11:0] signed Q10 counts saturated into [-1024,1023]; theta=c[7:0], c[30:8] must be zero (malformed: result=aux=0, fault=1). m1=d*cos, m2=q*sin, m3=(d+q)*(cos+sin) so alpha=round_up((m1-m2)>>>10) and beta=round_up((m3-m1-m2)>>>10), i.e. the transpose of the forward matrix. result[11:0]=alpha, result[23:12]=beta, result[31:24]=0. aux[7:0]=theta, aux[8]=first input saturated, aux[9]=second input saturated, aux[10]=|alpha| above the 11-bit range, aux[11]=|beta| above it, aux[31:12]=0. fault=1 only on a malformed control word.

See [common interface](../../doc/INTERFACE.md). Latency: 1 enabled edge(s); II=1 when output ready. Independent lanes per accepted beat: 1. Only accepted transactions update state. Reset clears pending output and state, even while CE is zero.

Hardware advantage: The same three slices that read the machine also write it: voltage commands leave the regulator in the rotating frame and must be transformed back inside the same beat to be useful to the SVM stage, and the inverse shares the table so no second ROM or second angle lag appears.

Independent integer model: `step("inv_park_s12", a, b, c, state)` in tools/fam_motor.py. Vector rows: 320, of which 128 run on the board. Board-set coverage: 126 distinct responses, 3 fault rows.
