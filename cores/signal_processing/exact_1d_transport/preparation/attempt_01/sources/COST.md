# Scheduled architecture and paper budget

SOURCE_ONLY; all physical/resource/performance results NOT_RUN. Memory risk LOW; control/arithmetic risk MEDIUM. No LUT, FF, DSP, BRAM, Fmax or power measurement is claimed.

One unreset packed synchronous single-port scheduled RAM holds B rows of {signed key X,source C,target C}: B*(X+2C), 768 default and 4608 maximum logical bits. Capture writes and compute reads are mutually exclusive. There are no simultaneous read/write edges and no read-before-complete-capture path. One registered read word feeds two cached row words; source and target requests serialize even when indices coincide. Each encountered source or target row is read at most once. No sorting, B^2 coupling RAM, flow history or external RTL dependency is used.

States and edge actions:

| State / encoding | Edge action and next state |
|---|---|
| CAPTURE 0 | On acceptance write RAM, latch masses/key, compare previous key, capture first tag; ADD_A |
| ADD_A 1 | Shared ALU source total addition; ADD_B |
| ADD_B 2 | Shared ALU target total addition; CAP_NEXT |
| CAP_NEXT 3 | More rows => CAPTURE. Complete => independently set mass bit; invalid/empty => SUMMARY; otherwise A_REQ |
| A_REQ 4 | B sentinel => SUMMARY; otherwise synchronous source read => A_LOAD |
| A_LOAD 5 | Cache row and mass. Zero => advance source then A_REQ; positive => B_REQ if target cache invalid, else CHOOSE |
| B_REQ 6 | B sentinel => SUMMARY; otherwise synchronous target read => B_LOAD |
| B_LOAD 7 | Cache row and mass. Zero => advance target then B_REQ; positive => CHOOSE |
| CHOOSE 8 | Latch positive minimum quantity; DISTANCE |
| DISTANCE 9 | Shared signed-extended larger-minus-smaller; initialize serial product; MULTIPLY |
| MULTIPLY 10 | Exactly C shared additions plus shifts; COST |
| COST 11 | Shared running-cost addition, increment count; FLOW |
| FLOW 12 | Hold all public fields. Only actual retirement => SUB_A |
| SUB_A 13 | Shared source residual subtraction; SUB_B |
| SUB_B 14 | Shared target residual subtraction; ADVANCE |
| ADVANCE 15 | After both writebacks advance exhausted pointers, invalidate corresponding caches; A_REQ/B_REQ |
| SUMMARY 16 | Hold unique last token. Only retirement => clear owner and CAPTURE |

Zero-bin pointer skips happen while loading, before a flow exists. Positive residuals/pointers never advance speculatively while a flow is held. COST makes running cost/count include the currently offered flow; FLOW performs no arithmetic until retirement. All summary geometry/quantity is combinationally zero.

Counting active edges from the first accepted input through the summary retirement (exclude absent-input edges and held-valid output edges): capture <=4B; serialized source+target request/load <=4B; each positive flow has CHOOSE+DISTANCE+C MULTIPLY+COST+FLOW+SUB_A+SUB_B+ADVANCE = C+7; a terminating end request plus summary <=2. Thus <=8B+F*(C+7)+2. The frozen conservative public bound is 8B+(2B-1)*(C+12)+16: 1012 default, 5100 maximum, including explicit slack of 5F+14. Invalid/empty frames are shorter. No always-ready or missing-input-independent wall-clock bound is asserted.

Scalar registers (logical bits; synthesis may optimize): RAM read word + two row caches =3R where R=X+2C (144/216 default/max); two totals=2TOTAL_W (40/60); pending masses=2C (32/48); previous key=X (16/24); residuals=2C (32/48); quantity+multiplier=C+C (32/48); multiplicand+product+running cost=3COST_W (108/162); captured tag=TAG_W (8/32); capture count+two pointers=3PTR_W (15/21); multiply index=max(1,clog2 C) (4/5); flow count=COUNT_W (5/7); state5+errors2+target-cache-valid1=8. Total declared scalar registers =444 default /679 maximum, plus RAM. Public held outputs are views of these stable registers; there is no additional duplicated output payload. The wide ALU and selectors are combinational, not a second storage allocation. Narrow counter increments/comparisons exist separately; only the data arithmetic is shared.
