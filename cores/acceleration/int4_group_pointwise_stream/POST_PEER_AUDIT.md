# Independent post-execution peer audit

PASS / NO_BLOCKER — worker_a, source and evidence review only.

Receipt: `reports/20261106T153204794699Z/results.json`

SHA256: `26222f1182fd9dbe21adcc6c8d51a2e8e51869660e1c4701e327a87edc525d61`.

All15 children passed:4 isolated preparations,3 syntax checks,4 compilations
and4 simulations. The exact archived command order/argv/cwd,17 current/archive
source pairs,24 tool pins,3 current/archive controls,15 terminal JSON records,
30 raw streams,8 vector/preparation-receipt files and4 original compiled images
were independently checked. Compile, persisted pre-execution and current image
hashes agree. The once guard matches the controls; there is one report attempt.

Core vector scalar outputs:5 /54 /32976; recovery scalar outputs:2 /6 /16.
Total core scalar outputs33059. The real RGB example checks73 packed outputs
(four scalar lanes each), comprising72 fixture pixels and1 recovery pixel.
There are14 reset assertions,12769 core output-hold checks,54 packed-output
hold checks,16244 saturated and15489 inexact core outputs. Counts from raw
PASS lines match the terminal JSON and expected metadata.

No timeout, cleanup entry, active child or helper is recorded. The longest
child execution is15.766 seconds, below the20-second hard limit. Tree5-second
and sole target2-second cleanup bounds were source-reviewed but not exercised.
Compilation has only the retained timescale diagnostics listed in JSON.

The audit used standalone stdlib byte/hash/JSON/raw inspection and a final
rehash of observed files. It did not import/AST-parse project code or execute
any project helper, model, HDL, simulator, synthesis, PnR, STA or board test.
Evidence is preserved unchanged. This is bounded simulation evidence; hardware
and PPA remain unverified.
