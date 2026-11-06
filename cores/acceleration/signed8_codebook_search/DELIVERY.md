# Current package entry

Use [rtl/signed8_codebook_search.sv](rtl/signed8_codebook_search.sv) with
[files.f](files.f) for exact resident signed8 code selection, reconstruction
and signed9 residuals. Use [example/codebook_residual_encode.sv](example/codebook_residual_encode.sv)
with [example/files.f](example/files.f) for the actual RNE signed8 residual
encoding composition. Resolve both filelists from the package root.

[README.md](README.md) defines configuration publication, count-based query
capture, deterministic nearest ties, distance margins, summary/replay ordering,
reset and backpressure. The example can hold encoded output while accepting a
later query; tags and LAST preserve vector association. [ARCHITECTURE.md](ARCHITECTURE.md)
defines storage, arithmetic bounds and a conditional RTL service budget.

Current finite evidence is [QUALIFICATION.json](QUALIFICATION.json) and
[QUALIFICATION.md](QUALIFICATION.md). The sealed README and manifest retain
their pre-execution authoring status. All15 planned children passed across
three core profiles and the real wrapper; hardware remains HW_UNVERIFIED.
The [independent post-execution audit](POST_PEER_AUDIT.json) found no discrepancy.
The consumed one-shot runner and its original controls/evidence remain intact.
Any future execution needs its own independently reviewed gate.

No external trained codebook is mandatory: configure components through the
public interface. All required RTL and license material are present locally.
The example's unchanged requantizer alias is an exact baseline blob at
05b9614c3962e9d4ae934c4b9c7bd315cc01aed4; no new support bridge or mature source
modification was needed. [SOURCES.md](SOURCES.md) records the reference-only
external discovery and original-source license boundary.
