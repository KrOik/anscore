# Order5 stimulus correction and finite repair

The first run is permanently retained at
`reports/20261106T082558407905Z/results.json`, SHA256
557c45f25ad0f4359db17810ee392cf6d21a470131bf4527e98576005db99756.
It completed10 PASS /1 FAIL, including three successful core simulations.
The failed example image SHA256 is
6765253896c28ef078fc35d897e41ff14ccabdba178a03d4b0a914e472e088d3.
The original plan, inputs, three vectors,22 raw streams and four images remain.

The first failure at5375000ns is a hand-derived example-stimulus mistake, not an
RTL or independent-core-oracle discrepancy. Before the fifth IOC, position=1,
buy_open=0 and sell_open=5 from external ticket900; the configured interval is
[-5,5]. Requesting another sell2 gives lower endpoint1-(5+2)=-6, correctly
rejected as LIMIT_EXCEEDED before the matcher. The intended scenario is a legal
reservation followed by an out-of-price-limit IOC. A sell1 has endpoint-5;
best bid9 is below its sell limit10, so no fill occurs, reason2 and remainder1.
Its own reservation is cancelled, leaving position1/sell_open5 and the book
unchanged. All subsequent original expectations remain applicable.

Root authorized only two literals on that single TB line: request quantity2 to1
and expected remainder2 to1. `REPAIR01_TB_PATCH.json` records both complete line
fragments and the old/new byte hashes. The failed TB is also retained in
`planning/tb_position_gated_ioc8.failed_order5.sv` and the original executed-input
archive. Every RTL source, oracle, core TB, other example stimulus/expectation,
assertion, original runner, docs and original finite plan remains unchanged.

`run_repair01.py` is independent and imports no old runner or model. Its bounded
child executor is copied as source from this package's reviewed first-run runner.
Its plan contains exactly the example compile and simulation, no syntax checks,
no successful core reruns, no oracle/preparation calls. Source review by C/root
and a separate root execution gate are required. Record-first persistence,
20second child deadline,5second tree termination,2second drain, fail-stop and
single-attempt guards apply. All original failure artifacts, current/new source
archives, tool hashes, exact argv/cwd, raw streams and the new image are protected.
No file is deleted or cleaned by the runner.
