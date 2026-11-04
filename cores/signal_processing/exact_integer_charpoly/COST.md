# Logical declaration budget

The production RTL declares six payload arrays and the following scalar storage. Combinational wires are not register declarations.

`K=clog2(N+1)`, `CW=clog2(N*N+2)`, `SW=max(1,clog2(COEFF_W))`.

| Scalar declarations | Bits |
|---|---:|
| a_q | DATA_W |
| v0_q, v1_q, g_q, dot_acc, mul_shift, mul_acc | 6*WORK_W |
| q0_q, q1_q, mul_factor | 3*COEFF_W |
| tag_q | TAG_W |
| m,r,i,j | 4*K |
| count, mul_step | CW+SW |
| state, errors, vec_bank, coeff_bank, power_mode, mul_negative | 5+3+4 |
| Total | 6*WORK_W+3*COEFF_W+DATA_W+TAG_W+4*K+CW+SW+12 |

Payload arrays total `N*N*DATA_W+2*N*WORK_W+(N+1)*WORK_W+2*(N+1)*COEFF_W`. Default payload/scalar are 1,001/399 bits; maximum N8/W12/T8 are 5,608/1,085. TAG_W32 adds24 scalar bits to the maximum profile's tag8 ledger. The parameter envelope maximum scalar value is therefore **1,109 bits at N8/W12/T32**, while the frozen maximum compute profile T8 has1,085. There is no claim that the frozen T8 profile enumerates the entire Cartesian parameter envelope.

The multiplier's true common operands are WORK_W x COEFF_W, with DATA_W useful factor bits during vector phases. A shared WORK_W adder serves MUL and ACC; one WORK_W and one COEFF_W unary sign path remain real arithmetic carry structures. Address arithmetic is by fixed N plus narrow controller indexes. The storage count does not imply BRAM placement, physical packing, LUT count, DSP count, clock frequency or power. In particular six separate small, wide RAM banks carry a fragmentation/inference risk.

LeVerrier was considered: two full WORK matrices would require 1,610/16,817 payload bits at default/max compute settings, N^4 narrow products, and N exact small-divisor divisions. Berkowitz reduces payload storage and the fixed arithmetic schedule while requiring honest wide x wide convolution operands and their intermediate proof.
