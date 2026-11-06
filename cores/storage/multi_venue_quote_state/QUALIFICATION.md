# B40 multi_venue_quote_state qualification

The reviewed finite plan passed on its first execution: 11/11 children and all four simulations, with no retry, repair or successful-profile rerun. The only pre-execution review repair changed an unreachable actual-L2 reset cut to WRITE1_WAIT=9; model and HDL counts were still zero.

The three core profiles `(1,1,1)`, `(5,3,8)` and `(32,8,32)` checked 2,252 responses, 1,126 actually admitted future QUERYs, 13,512 held clocks, 13,881 future preoffers and 24 resets. The dual-venue example accepted 71 commands and checked 66 responses, including 33 future QUERYs, 21 actual L2 operations, two disabled results, 267 held clocks, 132 blocked clocks and six resets. Five example operations were deliberately cancelled by reset.

All 15 frozen inputs and their exact archives, two tool binaries, the executed plan, three saved vector files, 22 raw streams, 11 argv/cwd/limits records and four compiled images were independently checked by standard-library parsing and hashing without importing a checker/model or executing HDL. Both mature dependencies match baseline raw bytes. Source and example file lists have complete explicit closure and no includes. See `QUALIFICATION.json` and `EVIDENCE_AUDIT.json` for hashes, profile counts and scope.

Compile diagnostics only identify modules without explicit timeunit/timeprecision; raw stderr is retained. No synthesis, place-and-route, STA, board, PPA or inherited regression was run. Maturity: `LINT_PASS`, `UNIT_SIM_PASS`, `INTEGRATION_CANDIDATE`, `HW_UNVERIFIED`. Backend failures have no rollback guarantee; protocol eligibility and timed freshness are outside scope.
