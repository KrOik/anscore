# Proposed finite verification, not an executable approval

Status: SOURCE_DRAFT / NOT_RUN. Neither model preparation, Python/HDL parser,
compiler nor simulator has been invoked. This plan is review material; it does
not authorize execution. Root and an independent peer must first review full
source and the exact executable paths, argv/cwd/environment, imported/read
inputs, output paths, hashes and single-use guards. The root may bind this
small matrix into the common B50 lifecycle helper after that review.

All cwd values below mean this package directory. All outputs must be under
this package's dedicated work tree, initially absent, and must be retained.
No command imports a sibling package's helper, runs history regressions,
synthesis, mapping, PnR, STA, board tools or PPA measurements. No automatic
retry, deletion, historical baseline rewrite or output overwrite is proposed.

Proposed finite children, after the exact common gate is reviewed:

| Step | Shape and intended scope |
|---|---|
|1 preparation| Python -B tools/prepare_vectors.py --output-dir work/preparation_once |
|2 minimum core elaboration| Icarus -g2012 -tnull -s rgb_screen_matte -Prgb_screen_matte.TAG_W=1 -f files.f |
|3 minimum example elaboration| Icarus -g2012 -tnull -s screen_matte_over -Pscreen_matte_over.TAG_W=1 -f example/files.f |
|4 core compile| Icarus -g2012 -I sim -s tb_rgb_screen_matte -o work/core32.vvp -f files.f sim/tb_rgb_screen_matte.sv |
|5 core simulation| VVP work/core32.vvp +VECTORS=work/preparation_once/vectors.txt |
|6 example compile| Icarus -g2012 -I sim -s tb_screen_matte_over -o work/over28.vvp -f example/files.f sim/tb_screen_matte_over.sv |
|7 example simulation| VVP work/over28.vvp +VECTORS=work/preparation_once/vectors.txt |

Seven children are proposed: one preparation, four compiler/elaborator and
two simulations. Absolute executable names/versions/hashes are deliberately
not guessed here. Exact common lifecycle controls remain root-owned: bounded
child20seconds, tree-termination auxiliary5seconds and target-exit observation
2seconds, initial/terminal/validated sidecars, exclusive once guards and raw
stdout/stderr. A compiled image must be checked and its SHA persisted in the
simulation initial sidecar before process creation. Nonzero exit, timeout,
bad marker or unexpected child state must stop the sequence and retain the
failure. No success statement may rely only on prepared vectors or compile.

## Independent vectors and actual TB obligations

The authored loops are expected by source inspection to yield1262 rows, not
an observed count. Preparation will report the actual count/hash and remain
PREPARATION_ONLY. It uses arbitrary integer/Fraction arithmetic, not the RTL's
folded /255 or eight-stage quotient. Its assertions require all256 alpha
bytes, invalid windows, several exact-half cases and the520200 metric bound.

The fixtures include512 exact alpha ramps across both screen channels,
black/white common-offset invariance, zero/full strengths, hard equality,
clamp equality, invalid order, thresholds above reachable metric, opposite
extreme colors, six directed half-tie configurations and384 seeded random
per-pixel key/window/strength/channel changes. Coordinates/tag/user span their
full public domains, with explicit zero/max/high-bit metadata fixtures. Flags
are intentionally opaque rather than validated as
frame syntax. Backgrounds include transparent, opaque, partial premultiplication
and deliberately invalid production destinations, including simultaneous
matte+destination errors.

Core TB default TAG_W32 and example TB default TAG_W28 check every retired
data/status/metadata field in order. First128 input pairs and outputs form
dense bursts with exact15/18-clock transfer latency and II1 assertions.
Later source gaps, independently delayed background arrivals and downstream
stalls check ownership and held output stability; a complete post-run quiet
window rejects extra output. Source and background must accept atomically.

Core live-reset probes observe stages0/3/7/11/14. Example probes observe matte
0/7/14 and actual production blend stages1/3 (combined15/17). They assert the
target valid before reset; held-final-output probes also check stability.
After reset masking, complete quiet windows reject canceled-token leakage.
Two additional example probes reset unmatched foreground/background tokens.
These counts refer to targeted probes, not the total reset pulse count.
Each TB has a finite cycle budget and watchdog independent of the external
wall-clock process limit. EOF checks consume only trailing whitespace via
fgetc rather than relying on fscanf's failed-tail return convention.

The minimum configurations are syntax/elaboration-only in this proposed
matrix; maximum-tag configurations get actual finite simulation. This is not
exhaustive pixel/configuration coverage, formal verification, physical timing
or camera/display qualification. Any source correction needs an explicit new
source freeze/review and separate retained attempt, not an automatic rerun.
