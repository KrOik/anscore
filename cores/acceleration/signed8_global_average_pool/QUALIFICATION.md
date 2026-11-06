# B41 finite qualification

First execution PASS: 11/11 HDL children, four successful simulations, no
failed child, no repair/retry. Source-only independent review: worker A.
The reviewed pending plan SHA was
`f974a88d72b663da210e1e04ad5923cafab9276e6caf0ac233c6fcc04281c786`;
only source_review changed to NO_BLOCKER_A before the executed plan
`28f0c31abfc0b082c71e1d174c979f73162208ef3437c61a6b7f668b4920134e`.

Receipt `reports/20261106T072333773864Z/results.json` SHA256
`7d52dee0108b41fbf05be631e7ce1f94a53eb85a88b470aa3adc9d49f006eea5`.
The receipt binds 16 exact current/archive inputs, plan, tools, four archived
vectors and 22 raw streams. All input hashes checked before each child and at
closeout; every simulation has one PASS marker and natural $finish.

Four deterministic planning oracle calls plus four archived vector preparations.
No historical runner/model was executed. Profiles:1/1/tag1,5/31/tag8,
64/65536/tag32 and actual4/67/tag8 classifier. The model uses signed floor divmod,
independent of RTL's unsigned-magnitude division and sign restoration.

Vector scope:143 commands,136011 accepted inputs,738 checked outputs,337
nonzero remainders,6 clipped classifier logits,133687 measured input II2
intervals. Includes signed extrema, both signs of half ties, nondivisibility,
constant-per-channel patterns, dimensional rejection, early/missing LAST,
source gaps,2955 held-output clocks and652 held-response clocks (the hold counts
include reset scenarios). Five reset cut points per profile,24 resets total,
and20 checked future frames after cancellation/reboot. The core's29-clock first
valid delay and29-clock channel retirement interval are statically derived and
source-reviewed; the simulation explicitly measures input II2, not those output
latencies. Maximum product4194304 samples was not run as a single transaction.

Four compile stderr files contain only missing-design-timescale warnings from
unchanged dependencies/new synthesizable RTL. Syntax/simulation stderr is empty.
Successful images remain task-local and outside Git. Earlier cleanup was blocked
by policy; no deletion attempt or alternative cleanup mechanism was used here.

Status: LINT_PASS (listed Icarus syntax only), UNIT_SIM_PASS (these four finite
profiles), INTEGRATION_CANDIDATE, HW_UNVERIFIED. No combined compile, inherited
regression, synthesis, PnR, STA, board, PPA or model-accuracy claim. The frozen
README is pre-execution architecture text; this report and QUALIFICATION.json
are the qualification authority for this exact version.
