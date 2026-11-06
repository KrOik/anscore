# Current package entry

Use [rtl/multistop_linear_gradient.sv](rtl/multistop_linear_gradient.sv) with
[files.f](files.f) for exact Q10.8 point-to-gradient paint. Use
[example/linear_gradient_porter_duff.sv](example/linear_gradient_porter_duff.sv)
with [example/files.f](example/files.f) for the actual unchanged Porter-Duff
composition. Resolve both filelists from this package root. All required RTL,
dependency references and license material are local.

[README.md](README.md) defines endpoint coordinates, ordered premultiplied
stops, duplicate-stop and degenerate behavior, management, ownership and reset.
A BEGIN invalidates the previous geometry/table and requires all stops again.
Queries remain owned through the final held output; the wrapper retains the
destination/mode and withholds management through public composition retirement.

The current finite result is recorded in [QUALIFICATION.json](QUALIFICATION.json)
and [QUALIFICATION.md](QUALIFICATION.md). The independent EOF-check followup
passed12 HDL children and five simulations, with3175 main query outputs and
12700 main held-output checks. The complete retained history includes the
original failure:5 preparation children,16 HDL children,15 HDL PASS,1 HDL FAIL,
0 HDL TIMEOUT and6 original images. [FAILURE_DIAGNOSIS.md](FAILURE_DIAGNOSIS.md)
explains the first TB EOF assertion and its evidence boundary. Both receipts,
all raw streams and all original inputs remain intact.

The separate [followup01](followup01/README.md) changes only the copied TB EOF
consumer, uses the original five vector/preparation pairs, and executes no
new preparation or oracle/model call. The original README and manifest remain
sealed in their authoring state. Both once-only gates have been consumed;
future execution requires its own reviewed controls and gate.

[DEPENDENCY_PROOFS.json](DEPENDENCY_PROOFS.json) proves the four unchanged
baseline dependencies. [SOURCES.md](SOURCES.md) and
[EXTERNAL_SOURCE_REVIEW.json](EXTERNAL_SOURCE_REVIEW.json) record public-spec
and immutable upstream reference review with the original-source boundary.
Hardware remains **HW_UNVERIFIED**; no synthesis, physical performance, full
SVG/CSS compliance or whole-system graphics qualification is claimed.
