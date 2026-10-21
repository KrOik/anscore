# Fixed-width round v2 audit (diagnostic source, not promoted)

Frozen SHA-256: `149689ed710f84d83dfec121657bbabab5050da0e59932af75ee41382eabc1a0`.
Let A=32768, S=65536, r=pole/S, 0<=r<=1-1/S. Sample integers satisfy |x|<=A.
State units have16 fractional guard bits relative to sample integer units.

| Node | Reachable absolute bound / range | Declared signed width |
|---|---|---:|
| x_state, prev_state | [-2^31,2^31-2^16] | 34 |
| blocker ideal state | 2*A*S=2^32 by impulse-response L1 norm<=2 | 34 |
| blocker state incl. quantization | <=2^32+2^15 | 34 |
| feedback = pole*state | <2^16*(2^32+2^15), below2^49 | 51 |
| rounded_feedback | <=2^32+2^15+1 | 36 (consumers bounded34) |
| blocker baseline numerator | <=A*S+2^32+2^15+1, below2^33 | 34 |
| weighted=(S-pole)*x | [-2^31,2^31-2^16] | 34 |
| weighted_state=weighted*S | [-2^47,2^47-2^32] | 52 |
| baseline feedback+weighted_state | conservative <2^49+2^47, below2^50 | 52 |
| baseline state | invariant [-2^31,2^31-2^16] | 34 |
| baseline residual numerator | [-4294901760,4294901760] | 34 |

Blocker rounding disturbance per recurrence is <=0.5 state unit. Its accumulated
bound <=0.5/(1-r)<=32768 state units (0.5 sample LSB), explaining the extra2^15.
Zero initial states satisfy the bounds. Baseline is a convex combination of prior
state and x*S, followed by integer nearest-even rounding; the integer endpoints
remain invariant. No truncation to34 bits discards reachable information.

### Signed shift and intermediate review

- x and previous_x are sign-extended from16 to34 **before** shifting16; no16-bit
  shift truncation. Feedback multiplier inputs explicitly signed17 positive pole
  and signed34 state, product51. Weighted coefficient is signed18, allowing+65536,
  multiplied by signed16 input, product34.
- Weighted product is sign-extended to52 **before** shifting16. Feedback is
  sign-extended from51 to52 before sum; no mixed unsigned shift operand appears.
- Blocker baseline identity uses previous_x*S-rounded_feedback, exactly equal
  to x*S-state_next, while avoiding the longer x/updated-state cancellation path.
  With fixed-point feedback rounding already complete, this rearrangement adds
  no rounding boundary and changes no mathematical expected value.
- Output rounding retains an18-bit signed quotient, whose range±131072 contains
  reachable baseline numerator/S (<98305), blocker state/S (<65537) and residual.
  Generic arbitrary34-bit positive max could round out of18 bits; that input is
  outside the proven reachable domain and is not claimed by this local helper.
- Product rounding retains36 bits. Reachable quotients above are far below the
  generic36-bit boundary. Saturation input is signed36 and occurs only on output.

### RNE negative and tie audit

For two's-complement value v, arithmetic quotient q=floor(v/S), low16 bits give
remainder t=v-q*S in[0,S-1]. Add1 iff t>S/2 or (t=S/2 and q odd). This is nearest,
ties-even for both signs. Examples: -0.5→0, -1.5→-2, -2.5→-2; +0.5→0,+1.5→2.
Unlike old abs/negation logic, it needs no wide absolute-value or sign restoration.

The recurrence is otherwise bit-exact, including feedback bias/deadband: no claim
that RNE makes accumulated error identically zero. `test_rtl.py` compares all
three modes/poles0,32768,65024,65535; `test_mean_long.py` checks full-ring wrap.
`test_rounding_v2.py` checks all65536 residues at quotients-2,-1,0,1 plus range
boundaries against the independent old abs/divmod model. Physical confirmation
remains required; these proofs do not identify the original mapping/timing defect.

Executed helper regression:
`../../evidence/rounding_v2_20260925_033923_239698/summary.json` PASS,
262198 output cases and54 product cases. V2 subsequently failed a physical
baseline pole65535 word while source replay passed; width/RNE correctness alone
does not constitute hardware acceptance. V3 retains this arithmetic and registers
the numerators before output conversion for physical diagnosis.
