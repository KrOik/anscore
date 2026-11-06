# B45 qualification delivery

Actual status: **LINT_PASS / UNIT_SIM_PASS / INTEGRATION_CANDIDATE / HW_UNVERIFIED**.
This delivery supersedes the frozen source-only status in README and manifest;
those exact executed inputs remain unchanged.

Use `files.f` for the core or `example/files.f` for the actual RGB decoder.
The one gated run in `reports/20261106T132343152740Z/results.json` passed four
numerical preparations, eleven HDL children and four simulations. The independent
direct scatter oracle performed 35 evaluations. Profiles include minimum scalar,
RGB multichannel, maximum parameter compilation, W1023 row replay, C/O16 1x1,
nonpower channels, full32 tags and the real RGB serializer/packer composition.
Every simulation checked four live reset cancellations with fully checked recovery
frames, a held future command, output stalls and configuration ownership.

Current/archived sources, review, plan, vectors, child records, raw streams and
four retained executable images were independently rehashed after execution.
All 15 child PIDs exited zero in less than20 seconds; no cleanup was invoked.
`QUALIFICATION.json` contains exact counts, hashes and observed markers.

Full maximum-height images, exhaustive inputs, synthesis, PnR, STA, board tests and
physical area/frequency/power remain unverified. The signed feature-to-RGB preview
adds128; it does not establish trained-network accuracy. No automatic retry ran.
