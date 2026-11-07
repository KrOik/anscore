# Finite functional plan, source-only

Baseline: c9117a22459e954d496dfa66dd94d6f67188c862. This document and the model,
TB, and runner are new unexecuted source. No syntax, model, AST, HDL, synthesis,
PnR, STA, board, PPA, or historical regression execution is authorized by this
document. Root and an independent peer must inspect the exact final source and
metadata before a separately gated single execution. SOURCE_REVIEW.json starts
PENDING and blocks the runner. No automatic retry is permitted.

The proposed suite has exactly15 target children: four isolated Python vector
preparations, four Icarus compiles, four vvp simulations, and three expected
elaboration rejections. Compilation retains exactly four vvp images, including
the actual adapter. Static profiles are minimum(MAX3/TAG1), typical(16/8),
maximum(256/32), and example(256/8 with USE_EXAMPLE1). Rejections are MAX2,
MAX257, and TAG0. An expected rejection must actually return nonzero and identify
the intentional undefined parameter module; its raw nonzero exit remains in the
process record, while a separate validation records that the rejection was
expected. It is not rewritten into an exit0 child.

The fit model uses exact Fraction elimination of [c,s,1] and exact normal
residual checks, with pairwise Gram diagnostics and a3x3 determinant. Decimal
trig checks the used quantized CORDIC basis within1 LSB. Cases cover invalid
commands, early/missing last, one/two-phase rank loss, full-rank three-point
fit, DC rejection, nonorthogonal near-rank windows, exact rational cosine and
negative-sine amplitudes, arbitrary nonpower length, phase wrap, full signed16
samples, and three256-beat windows. Profile case counts are11/16/19/19;
vector sample counts19/74/842/842. The testbench adds five reset-cancellation
commands and eight sample beats per profile. It exercises collection, trig,
sample multiply, centering, and held-output reset, source gaps, command ownership,
every result field, and held-result stability. Its watchdog is1,000,000 nonreset
cycles. Simulation counters must match cases, commands=cases+5,
samples=vector_samples+8, results=cases, reset_edges=19, and USE_EXAMPLE.
The startup reset contributes four edges (one before reset_core reaches its
first falling edge, then three in the task); five later resets contribute three
each. The original unexecuted18-edge metadata candidate is retained in
`.git/anscore-b50-tone-fit-source-review/reset-count-18/` with its revision record.

Every target has20s total wall time including spawn/PID persistence. Timeout or
failure stops the suite. If termination is needed, one hidden taskkill helper
has5s; independent nonwaiting helper/target direct kills follow as needed, then
one2s target observation interval. No target/helper second wait is allowed.
Unconfirmed termination blocks subsequent work and is retained as failure.
Raw stdout/stderr, PID, truthful terminal code, cleanup history, initial record,
terminal record, metadata-validation record, original inputs, and all generated
images are retained. Original bytes and negative results are never overwritten.

The runner executes the archived oracle under `-I -B`, does not import it, and
compiles only the explicit local closure. It pins source/tool bytes, inherited
and effective PATH, baseline via native .git metadata, exact argv/cwd/order,
the one-attempt guard, review, plan, seal, and pre-execution vvp image hashes.
No Git subprocess is used. Reports are created only by an approved future run.

Finite success would establish these profiles and directed functional cases
only. It would not establish exhaustive correctness, physical qualification,
unbounded throughput, ideal-trig fitting accuracy, or near-singular robustness.
