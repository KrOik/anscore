# Current package entry

Use [rtl/price_time_order_matcher.sv](rtl/price_time_order_matcher.sv) with
[files.f](files.f) for bounded single-instrument per-order price-time matching.
Use [example/two_client_limit_matcher.sv](example/two_client_limit_matcher.sv)
with [example/files.f](example/files.f) for the actual two-client round-robin
composition and owner-routed responses. Resolve both filelists from the package
root. All required RTL, dependency references and license material are local.

[README.md](README.md) defines command, fill, response, capacity and reset
semantics. NEW requires a free slot before any fill, even for a fully executable
taker. A residual joins the tail; partial makers keep time priority. CANCEL
followed by a separately retired NEW is the available non-atomic replacement
sequence. Reset discards an epoch and remaining outputs; consumers must
reconcile already accepted fill prefixes.

Current finite evidence is [QUALIFICATION.json](QUALIFICATION.json) and
[QUALIFICATION.md](QUALIFICATION.md). All14 planned children passed, including
four successful simulations. The reported main-fixture-plus-example counters
are581 completions and49 fills; core reset preambles are outside those counters.
The sealed README and manifest retain the pre-execution authoring state.
Hardware remains **HW_UNVERIFIED**. [Author](POST_AUTHOR_AUDIT.json),
[root](POST_ROOT_AUDIT.json) and [independent peer](POST_PEER_AUDIT.json)
post-audits found no discrepancy. The consumed one-shot gate and original
execution evidence remain intact; future execution needs its own reviewed gate.

[DEPENDENCY_PROOFS.json](DEPENDENCY_PROOFS.json) records both unchanged baseline
blobs; no support bridge or mature dependency source was changed.
[SOURCES.md](SOURCES.md) records reference-only discovery and the original-source
license boundary. No venue certification, persistent recovery, physical
performance or whole-system financial qualification is claimed.
