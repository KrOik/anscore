# Fixed fixture and raw formats

All fixtures are canonical ASCII with LF and a final newline. No fixture is
present before the uniquely approved preparation. CASE_TABLE freezes5 profiles,
30 main frames,10 fresh frames,10 input-only reset probes and10 groups. Probe
recipes are materialized as source pixels only; they are never numerically
solved. Each group contains input.txt, expected.txt and expected.json; the3
reset groups additionally contain probe.txt. CERTIFICATES.json makes34 files.

Scalar input starts with frame count. Each frame header is
`C sequence bright delta min max P Q tag error`, followed by N lines
`I index pixel sof eol`. The file ends with `END` and no trailing tokens.
Expected output starts with frame count, then per-frame header
`C sequence error tag` and N lines
`O index parent level area num den canonical selected errors tag sof eol last`,
then END. expected.json stores those complete tuples, frame configs, node
proofs and fixed boundary witnesses; no wide packed fscanf fields are used.

After the first pixel, the TB deliberately changes tag by xor1 (masked to
TAG_W), inverts bright and drives zero for Delta/areas/P/Q, while preserving
each held beat. This verifies first-transfer configuration/tag ownership.
Input gaps occur at fixed indices, not through random search. Each scored
output is stalled for exactly at least two active cycles before acceptance.
All result fields, flags and metadata are compared against stored scalar tuples.

Raw stdout contains only nonnegative decimal integers with single spaces:

| Prefix | Integer count | Meaning |
|---|---:|---|
| IN / PIN |12|sequence,index,pixel,sof,eol,tag,bright,delta,min,max,P,Q|
| OUT / POUT |14|sequence,index,parent,level,area,num,den,canonical,selected,errors,tag,sof,eol,last|
| REC |10|sequence,Hwork,A,B,E,F,first_latency,output_count,blocked_input_cycles,held_output_cycles|
| RESET |6|reset_id,new_state,child_state,mul_purpose,mul_step,output_index|

A main frame has exactly IN*N,OUT*N,REC in that order. A reset episode has
PIN*(3 for R0 else N), POUT*(N-1 only for R8), RESET, then its fresh
IN*N,OUT*N,REC. No extra, missing, unknown or reordered sequence is accepted.
The terminal line is exactly `PASS group=<fixed_id> cases=<n> resets=<n>`,
followed by the exact Icarus source-line `$finish` footer with a positive1ps
timestamp divisible by5000. Stderr must be empty on successful children.

Reset predicates are fixed in BOUNDARY_CERTIFICATES and the TB: R0 partial
capture at index3; R1 histogram child state3; R2 child LINK22; R3 child record3
while collecting; R4 a deeper T_READ; R5 filter multiplier purpose2/step4;
R6 selected F_WRITE; R7 held first normal result; R8 held last maximum result;
R9 held config-error result. Each target is observed at a settled falling
edge (#1) and reset is asserted immediately before the next active edge.
Prior valid offers are cancelled only by reset. The following actual probe
first beat is held while the preceding fresh frame drains; it is not withdrawn.
Each cancellation is followed by a complete scored fresh frame, including
all tuples and the canonical selected last-bright witness.

POUT belongs only to cancelled R8 and is a metadata/shape prefix, not a hidden
probe numerical oracle. The independent reference is absent from all stored
and raw HDL checks. validate.py consumes existing JSON/text/tuples and checks
fixed boundaries, exact work formulas and full interleaved event order only.
