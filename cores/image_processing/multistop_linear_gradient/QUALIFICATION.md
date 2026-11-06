# Finite qualification with retained first-attempt failure

The independent `followup01` finite suite passed all12 HDL children, including
five completed core/composition simulations. The first attempt remains
**FAIL_STOP**, with one failed minimum simulation and its original image/raw
evidence intact. Hardware remains **HW_UNVERIFIED**.

| Attempt | Preparation | HDL PASS | HDL FAIL | HDL TIMEOUT | Successful simulations | Original images |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| First attempt | 5 | 3 | 1 | 0 | 0 | 1 |
| Independent followup01 | 0 | 12 | 0 | 0 | 5 | 5 |
| Combined retained history | 5 | 15 | 1 | 0 | 5 | 6 |

The first receipt is
[`reports/20261106T184434034464Z/results.json`](reports/20261106T184434034464Z/results.json),
SHA256 `afa70ae8be75c8f96a4496f892dd400caf69d008bf1f2515afd6eef6debaba92`.
Its minimum simulation reached the final vector EOF check and exited1 with
`extra vector rows`. Exact text parsing found no extra logical row in any of
the five vectors, only one trailing LF. The actual `$fscanf` return code was
not printed. This attempt emitted no successful simulation marker and did not
run its later directed checks or the four remaining compile/simulation pairs.
See [FAILURE_DIAGNOSIS.md](FAILURE_DIAGNOSIS.md).

The separate receipt is
[`followup01/reports/20261106T190048543353Z/results.json`](followup01/reports/20261106T190048543353Z/results.json),
SHA256 `67a3ca2da438d21aeaf213773c44b346441aa959745c7e4d33e143927ce8e18b`.
Only the copied TB EOF consumer changed: `$fgetc` reads to -1 and permits only
ASCII9/10/11/12/13/32 whitespace. Reversing that block reproduces the original
TB exactly. All original21 source inputs, all original controls and evidence
domains, and all four mature RTL dependencies remain unchanged. The followup
uses separate controls, guard, reports and images; its runner executes no
preparation, model or oracle import and reuses the original five vector/prep
pairs as explicitly pinned read-only files.

| Profile | MAX_STOPS | TAG_W | Actual Porter-Duff composition | Vector rows |
| --- | ---: | ---: | --- | ---: |
| minimum | 1 | 1 | No | 666 |
| ragged | 5 | 8 | No | 714 |
| maximum | 16 | 32 | No | 780 |
| blend_small | 5 | 8 | Yes | 714 |
| blend_maximum | 16 | 32 | Yes | 780 |

Every successful simulation independently reports15 cases,635 main outputs,
2540 main held-output checks,8 live-reset fixtures,8 recovery outputs,
2 future-query results and1 management-contention result. Across the five
completed simulations these are75 cases,3175 main outputs,12700 main held
checks,40 live-reset fixtures,40 recovery outputs,10 future-query results and
5 management-contention results. These counters describe the successful
followup only. They do not add the uncompleted first simulation, all reset
pulses or management commands, or partially canceled operations.

Coverage includes actual signed Q10.8 point projection; pad, repeat and
reflect with negative boundaries; five geometry shapes and extreme signed
coordinates; coincident endpoints; first/last and duplicate stops; equal-end
stops and one-unit gaps; final rational nearest-ties-even interpolation;
the35-point pixel-centre grid; held outputs; malformed/incomplete management;
publication and cancellation; and pending queries/management through final
public output ownership. Both composition profiles exercise the actual
unchanged Porter-Duff RTL, all13 legal modes and invalid-mode/destination
responses. The independent Fraction oracle is the original preparation owner.

The followup has12 exclusive immutable initial records,12 immutable terminal
records,12 validated sidecars,24 raw streams and5 original execution images.
The combined history retains21 initial/terminal records,20 validated records,
42 raw streams and6 images. Each simulation start durably binds the image SHA
and prechecked flag before process creation. Terminal/raw evidence precedes
marker parsing. All children exited, capture completed, and no cleanup or
active process remains. Both attempts retain20s child,5s helper and sole2s
target-observation policy, no automatic retry and no evidence deletion.

Seven followup syntax/compile stderr streams retain inherited timescale
diagnostics. The three that instantiate Porter-Duff also retain Icarus's
constant-select sensitivity expansion messages from that unchanged dependency.
All seven children exited0; simulation stderr is empty. These diagnostics are
preserved in full.

[QUALIFICATION.json](QUALIFICATION.json) binds both receipts, controls, audits
and scoped counters. [DEPENDENCY_PROOFS.json](DEPENDENCY_PROOFS.json) records
the four exact baseline raw blobs; this package adds no support bridge.
The sealed README and manifest intentionally retain their authoring state;
this additive qualification is the current execution record.

This is finite deterministic source and integration qualification. Synthesis,
PnR, STA, board, PPA and historical regression were not run. There is no device
fit, frequency, physical throughput, full SVG/CSS conformance, gamma/color-space
conversion, framebuffer/display or whole-system graphics qualification claim.
