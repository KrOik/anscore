# B44 finite qualification

LINT_PASS + UNIT_SIM_PASS + INTEGRATION_CANDIDATE + HW_UNVERIFIED.

One archived preparation imported the independent local oracle once and
generated all five frozen profiles. Three syntax checks passed, including the
maximum standalone and actual-book parameterizations. The original core
simulations passed N1/P1/Q1/T1, N9/P12/Q8/T5 and N64/P32/Q32/T32. Each completed
48 numerical snapshots, 192 held-result cycles, 47 genuinely pending future
header acceptances and three live reset cancellation/recovery probes. Their
literal row totals were 31, 216 and 1309.

The separately reviewed and uniquely gated followup passed both actual-book
profiles: L1/P1/Q1/T1 and L8/P32/Q32/T8. Their files contain 106 and 134 records,
including one reset record each. They completed 105/133 checked responses,
72/100 maintenance operations, 33 auction snapshots each, 420/532 held-response
cycles, 103/131 actual future request acceptances and five live reset/recovery
probes each. Both verified simultaneous auction priority and retained book
contents after indication. Output values, statuses, counts, tags and signed
imbalances matched the independent oracle.

The initial L1 book simulation failed during VPI startup because Icarus rejected
`$fscanf` writing directly into a two-dimensional array element. It ran no book
case, and the L8 pair was not launched. The followup declares a signed 64-bit
temporary, reads each field into it, checks the same conversion result and
assigns the original array element. Those are its only testbench changes.
The original failed source, plan, gate, receipt, raw output, vectors and image
remain unchanged. The followup reused the original two vectors and unchanged
RTL/dependencies, without another preparation, oracle import, syntax check or
core simulation.

Total evidence is one preparation and 15 HDL children: 14 PASS and one retained
FAIL, with five successful simulations. EVIDENCE_AUDIT.json binds both receipts,
all raw streams and six retained images. Executed files and source-only plan
history remain frozen; this document records the combined qualification.

These finite checks exercise the documented limit-only submitted-price policy,
width extremes, duplicate rows, eligibility and tie breaks, maintenance errors,
stalls, cancellation and recovery. They do not exhaust all books or parameters.
No synthesis, PnR, STA, board, PPA or inherited regression was run. The result
remains an indicative clearing service without allocation or venue certification,
and has no hardware resource or timing claim.
