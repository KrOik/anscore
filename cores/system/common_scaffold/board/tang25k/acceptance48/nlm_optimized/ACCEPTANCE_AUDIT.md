# Independent acceptance evidence audit

## Final read-only recheck — supersedes the historical counts below

Final ledger snapshot **2026-10-19T01:30:06.063592+08:00** records **48/48 FUNCTIONAL_BOARD_PASS_HOLD_UNPROVEN and 48/48 current-production source matches**. The earlier 44/43 counts below are retained as historical audit context, not current progress.

An independent read-only Python inspection found exactly 48 distinct public-entry rows in ACCEPTANCE_REPORT.md and checked all 48 selected board records. Every selected record contains at least three PASS runs, programmer return code zero, and exact UART bytes matching its frozen expected_uart.txt. Each record has a matching routed build summary; actual route/resource/device/setup gates pass, minimum reported setup frequency is at least 50 MHz, LUT4 is at most 15000, and MULT12 is at most four. No selected summary reports a hold violation, positive hold-violation count, or negative hold slack. Missing explicit hold/min-delay qualification remains unresolved; absence of reported violations does not prove hold closure.

All 48 retained routed JSON hashes match their selected board records. All frozen build_status source hashes checked correctly. DUT files represented in the final production hash manifest match their selected frozen source versions. All **202** listed final production files independently hash correctly. No discrepancies were found by these checks. The final scaler selection is `geo_optimized/scaler_production_v10/functional_board_accept_20261019_011217_20261019_012947_013658.json` and has three successful repetitions.

Reviewed report SHA256: `4515ac7e4eda1dec30ca530eafbe4d33dff8772a6c585176a705f6af5609044e`. Final production manifest SHA256: `4092cb8c54af6af78897f34c715e79374d26ec3ed0a2096ead7a824235bb47a6`. The report explicitly limits acceptance to these bounded fixtures, distinguishes this batch from the original 300+ inventory, excludes image/model quality and large continuous-video performance, and states that hold timing is unsigned. Its wording does not promote these results to full timing signoff.

Final audit command: inline Python via PowerShell, reading Markdown/JSON and recomputing SHA256 only. First invocation encountered Windows default GBK decoding; rerun with PYTHONUTF8=1 completed successfully. No simulation, synthesis, programming, or JTAG was run. Only this exclusive audit document was updated; no shared ledger or production file was changed.

Audit snapshot: acceptance_status.json dated 2026-10-19T00:59:08.296158+08:00, SHA256 `bf1a221c2ca7faaff4713295ec909969f9422f9a6dbbc61260d6cd06124e3210`. This is a read-only evidence review; no simulation, synthesis, programming, or capture was repeated for this audit. The owning integration agent is continuing source refreshes and board work, so later counts may differ.

## Conclusion and counting boundary

The selected scope is 48 public common-IP entry points, not the original inventory of 300+ entries. All 48 have simulation-pass entries. 44 distinct entry points have credible historical evidence of at least three successful SRAM programming and exact UART repetitions. Their status is **FUNCTIONAL_BOARD_PASS_HOLD_UNPROVEN**, not final delivery or timing acceptance. Four remain simulation-only: `cip_image_rotate`, `cip_image_super_resolution`, `cip_image_affine`, and `cip_image_perspective`.

Of those historical 44, **43 have a board-tested candidate whose DUT source set matches current production** at this snapshot. Two have changed dependencies: upsample (`img_geo_area_resample.v`, `img_geo_inverse_map.v`) and stitch (`img_filter_nlm.v`). Their previous board results remain historical evidence, but cannot certify the changed current source. The integration owner is refreshing/retesting these cases.

The threshold public wrapper is byte-identical to its frozen board candidate: SHA256 `a424cfd1f77b3f6cfce9ddd9aaa626793c3e7f9ba74ddea0721e4e297bf7d8a6`. It is present in the signal_video manifest but missing from `rtl_functional_sources.f` (which lists only its fixed implementation). This is a source-list packaging omission, not a threshold board/source mismatch. A check limited to that .f file would undercount exact entries by one.

## Evidence actually checked

For all 44 historical passes, the selected strongest available witness has intact frozen files matching build_status.json hashes, at least three successful programming/UART runs, programmer return code zero, and UART hex equal to both expected hex and the frozen expected_uart.txt. Routed JSON hashes agree with board and build summary records. Resource, device, routing, and 50 MHz setup gates pass for those selected witnesses. Existing retained bitstreams hash correctly. All selected tops reference the intended public entry point; all 44 UART expected digests recompute from frozen output vectors.

Eleven selected historical bitstream files are absent after space management. The frozen routed JSON and board records remain. Consequently those eleven image bytes cannot currently be independently rehashed. This limits artifact replay; it does not establish that recorded historical programming was fabricated. An older brightness witness has a legacy summary schema, but a newer strong witness exists in the same brightness_v5 candidate. Failed records are retained. No observed promotion of a simulation-only run into a fabricated physical-board pass was found among these 44 strongest witnesses.

The board execution script checks frozen simulation/build provenance, route and synthesized-netlist hashes, CST/device database binding, resource ceilings (15K LUT4-class, 4 DSP-class), setup at 50 MHz, successful SRAM programming, JTAG IDCODE, and exact UART bytes. It rejects explicit hold violations while permitting missing hold qualification only under the hold-unproven status. Thus these runs do not establish qualified minimum-delay/hold timing.

## Aggregation and golden limitations

The status refresher historically promotes a stable public-wrapper-matching board candidate without requiring an empty changed-dependency list. It also trusts board JSON rather than independently repeating the full board/build hash gate. Therefore its historical pass total alone must not be presented as a current-production exact total. The new separate current-source statistic addresses the counting distinction; full-source and provenance checks remain necessary.

Expected UART is generated from frozen expected vectors, not sampled DUT output. The hardware driver compares actual output data and SOF/EOL, counts, tags, expected response errors, accepted source/auxiliary/coefficient transactions, and unexpected memory traffic. Zero errors therefore conveys more than digest equality. Seven normal/fault simulation variants must not be described as seven physical-board modes: physical repetitions use the normal fixture.

Frozen provider/generator files do not necessarily include every transitively imported numerical oracle from signal_video. Frozen vector hashes bind the values used, and independent regressions supply additional oracle evidence, but an individual case directory is not always a hermetic numerical-golden regeneration package. This is a reproducibility limitation; no manipulated golden was observed in this audit.

## Functional scope limits

Board fixtures are deliberately bounded. Examples: FIR 8-bit/3 taps, FFT 16-bit/8 points, CIC rate 3/3 stages, resampler up3/down2, most image cases at maximum 8x6 pixels, full dehaze at 3x3, stitch 4x3/max shift1, and Bayer width8/raw8. NLM board coverage is 50 commands/408 outputs; its separate unchanged production regression covers six profiles, 334 commands/4266 outputs. CLAHE board coverage is 7 commands/100 outputs, distinct from its broader simulation suite. Framebuffer tests use synchronous acceptance memory, not external DDR timing qualification.

SRAM runs are volatile. A physical 50 MHz clock with DUT CE_DIV4 is not proof of full-rate video throughput. Per-IP bounded resource fits do not prove all IPs fit simultaneously. These fixtures do not establish arbitrary parameter/mode coverage, external peripheral interoperability, image-quality acceptance, learned super-resolution quality, or full-resolution continuous-video behavior. No security/TVLA/formal protection claim follows from these functional tests.

## NLM optimization evidence

NLM v10 is integrated into production and has three successful physical repetitions recorded in `case_v10/functional_board_nlm_bounded_control_v10_20261019_004733_573478.json`. Its isolated implementation uses 3470 LUT4, 1356 DFF, 2 BSRAM, and 0 MULT12; setup pre/post reports 65.51/53.15 MHz. Original golden, watchdog, and arithmetic wrapping semantics are preserved. Production original regression and shared-core compile evidence are under `evidence/nlm_serial_production_20261018T165008Z_328bfc10/` and `evidence/nlm_production_shared_core_check_20261018T165102Z_5ab44e56/`. Earlier failed candidates remain documented; v5's original watchdog timeout was not accepted merely because its UART fixture passed.

## Task status

Changed file: this audit Markdown only. Commands: read-only Python JSON/hash/file inspection, ripgrep source discovery, and direct review of acceptance/build/generator/driver scripts. Result: historical 44 board witnesses credible within bounded scope; current-source exact count 43; four simulation-only; hold qualification unresolved. No tests or synthesis rerun, no resource change, no JTAG use, no production/shared-ledger edit, and no temporary binary created.
