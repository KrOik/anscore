# Exact 1-D total-variation denoising

Status: SOURCE_ONLY; preparation, certificate execution, lint and unit simulation NOT_RUN. Hardware HW_UNVERIFIED. No synthesis, placement/routing, STA or board result is claimed.

`exact_1d_tv_denoise` returns the unique exact rational minimizer of

    (1/2) sum (y[i]-x[i])^2 + lambda sum |y[i+1]-y[i]|.

It accepts the complete signed sample vector and one nonnegative penalty. It computes the fitted levels internally, including both upward and downward jumps. No host-supplied partition, change points or fitted result is needed. This is the unweighted, one-dimensional TV proximal operator with no amplitude l1 term.

## Parameters and ports

|Parameter|Legal range|Default|
|---|---|---:|
|N|1..64 samples per frame|16|
|DATA_W|2..24 signed input bits; unsigned penalty has the same width|16|
|TAG_W|1..32 opaque tag bits|8|

Derived widths are C=ceil(log2(N+1)), I=max(1,ceil(log2(N))) and P=DATA_W+ceil(log2(N+4)). Denominators are unsigned C bits, indices unsigned I bits and numerators signed P bits. Illegal parameter values cause named elaboration failures `exact_1d_tv_denoise_invalid_N__see_README`, `exact_1d_tv_denoise_invalid_DATA_W__see_README` or `exact_1d_tv_denoise_invalid_TAG_W__see_README`.

|Port|Meaning|
|---|---|
|clk, rst|One rising-edge clock; synchronous high reset|
|s_valid, s_ready|Ordinary input ready/valid; exactly N accepted beats form a frame|
|s_data|Signed DATA_W-bit integer, including the minimum negative pattern|
|s_lambda, s_tag|Captured only with the first accepted beat of a frame|
|m_valid, m_ready|Ordinary output ready/valid; all output fields stay stable while stalled|
|m_numerator, m_denominator|Exact unreduced rational fitted value; denominator is in 1..N|
|m_index, m_last, m_tag|Original sample index, final-sample flag and the captured frame tag|

There is no CE, input-last, runtime length, mask, external memory or CDC interface. All sample bit patterns and all unsigned penalty values are legal. Later input-beat penalty/tag values are ignored. lambda=0 returns each sample with denominator one; N=1 returns its sample with denominator one. No numeric division, rounding, tolerance, saturation or result wraparound is used. Equal adjacent values may have different exact fraction encodings.

Both handshake outputs are masked while reset is asserted. Reset cancels a partial, solving or held frame; it does not reset RAM contents. A complete fresh frame overwrites every input address before solving, and every result address is written before output. Reset must be asserted through a clock edge before use. Output data while m_valid=0 is unspecified.

All N inputs are captured before solving. No next frame is accepted until the cycle following the final output handshake. A synchronous result read separates consecutive retirements, so an always-ready sink receives at most one sample every two clocks. Missing source beats or unbounded output stalls remove an absolute completion-time guarantee. A blocked future offer is not an accepted frame.

## Source lists and integration

Both `files.f` and `example/files.f` interpret every source entry relative to the package root, including when the list resides in `example/`. Run a compiler from this package directory. No directory-relative exception is needed. `files.f` selects the core, and `example/files.f` selects the core plus the all-port N=16/W=16/TAG_W=8 wrapper `tv16`. There are no source dependencies outside this package.

The core uses two disjointly scheduled synchronous banks and one shared signed shift/add/subtract ratio comparator. [MATHEMATICS.md](MATHEMATICS.md) proves the KKT sign convention, emission/restart invariants, intermediate bounds and state-cycle accounting. [COST.md](COST.md) separates logical storage and structural budgets from unmeasured device results. [SOURCES.md](SOURCES.md) records attribution and the independent-source boundary.

## Finite evidence plan

The source fixture has ten individually named analytic targets, each assigned to one profile and one fixed traffic schedule. Four separately named reset jobs use only reachable states, followed by the corresponding named fresh case. An aborted frame uses the complement of that case's tag; the fresh replay uses its original tag, so held old metadata is distinguishable. No Cartesian inputs, sign/partition enumeration, random sweep or inherited regression is included. The reference checks exact rational KKT certificates of those fixed targets; it does not implement the hardware's interval scan.

The normal p5 final-output future offer remains valid with unchanged zero data, penalty and tag until its real first handshake after the completed frame. `NEXTIN` records that single accepted beat of an unfinished next frame; it adds no complete numerical case or fitted output. The reset-held offer is cancelled by the existing reset. The TB monitors every pending input field until handshake or reset, and the raw parser enforces complete-owner input/hold/retirement order and a unique terminal PASS/FINISH/simulator-finish suffix.

The explicit plan has 26 future child commands: four named certificate/version/lint checks, six profile compiles, six normal simulations containing the ten named cases, four reset simulations and six named parameter rejects. Expected output rows are 162 normal and 24 reset-fresh; all are planning counts and have NOT_RUN status. Preparation and HDL require distinct root-reviewed seals. Merely running a source file is not an approved qualification. Every future child has a 20-second process-tree bound, complete raw streams, first-failure stop and no retry. Original failures and NOT_RUN slots must be preserved if a future attempt fails.

Package `.gitattributes` uses `* -text` to preserve exact source, fixture and raw evidence bytes in storage. The fixed stored-certificate banner writes canonical LF bytes directly on Windows.
