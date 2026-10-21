# Bounded grayscale Poisson blending

`poisson_blend_frame.sv` reconstructs a real gradient-domain solution from
source gray A, target gray B and a binary mask. It is not alpha blending and
does not consume host-computed solutions. Parameter geometry is bounded to
`1 <= WIDTH*HEIGHT <= 1024`, with each axis in 1..1024. All samples are 8 bits.

For each masked interior pixel p the module solves

`4*u[p] - sum(u[q], q in four neighbors) = sum(g[p,q])`.

Normal mode uses `g = A[p]-A[q]`. Runtime mixed mode chooses the source or
target directed difference with larger absolute value on **each edge**;
equal magnitudes choose the source. Every outer image pixel is forced to B,
even when masked. Unmasked interior pixels, including holes, are fixed B.
This anchors an all-one mask without an arbitrary null-space solution.
An empty mask, or an image without interior pixels, emits B and converges in
one sweep. An isolated masked pixel uses its four fixed target neighbors.

The initial estimate is B. Raster-order Gauss-Seidel updates every active
pixel, then a separate read-only pass measures the actual maximum absolute
discrete-equation residual. Each iteration includes one update sweep and one
residual scan. Internal values are signed 28-bit Q8; `/4` is an arithmetic
right shift (floor toward negative infinity). Iteration values are not clipped.
The emitted byte is `clip(floor((u_q8+128)/256),0,255)`. Fixed boundary samples
remain exact. Memory reads are synchronous, with one shared neighbor address
and serial neighbor processing, suitable for Gowin block RAM. Division uses a
shift; no DSP or floating arithmetic is required.

START snapshots `cfg_max_iterations` (1..255), `cfg_tolerance` (24-bit Q8
equation-residual units), and `cfg_mixed`. A tolerance of 256 means one gray
level of equation residual, not a one-gray reconstruction error guarantee.
`iterations` counts completed update/residual pairs. `converged` is asserted
only if the measured full residual is <= tolerance. At the iteration limit,
the current reconstructed frame is emitted even if convergence has not been
reached, and this is reported by `converged=0`. Residual accumulation and the
threshold comparison are 32 bits; the exposed 24-bit residual saturates if
needed. Approximation errors at the iteration limit are retained in evidence.

Inputs transfer only with CE and valid/ready. SOF occurs only on the first
pixel and EOL on each row end. Exactly N tuples are captured before solving.
Output valid/data/markers hold through backpressure and CE stalls. DONE
remains asserted until CE-qualified done-ready. Synchronous active-low reset
overrides disabled CE and aborts the current transaction; RAM need not be
cleared because the next transaction captures every location first.

Error 1 rejects an invalid iteration limit or elaborated geometry, producing
no frame and preserving preceding statistics. Error 2 records malformed
SOF/EOL; N tuples are still consumed, solved and emitted, then held DONE
reports the error. Fewer than N input tuples wait for completion or reset.
Statistics remain stable after completion until the next valid START. The
design is a small serial engine, without real-time/full-resolution claims.

Run from repository root:

```powershell
python -B cores/system/common_scaffold/image/poisson_blend/run_tests.py
python -B cores/system/common_scaffold/image/poisson_blend/run_synthesis.py
```

Tests compare every emitted gray/marker and every signed Q8 solution RAM word
against an independent integer implementation, plus exact iteration,
convergence and residual statistics. Fixtures cover both gradient modes,
empty/full/holed/isolated masks, thin geometry, negative/over-255 solutions,
iteration limits, changed live configuration, framing errors, invalid START,
CE/backpressure, held DONE and disabled-CE reset followed by a complete frame.
SciPy sparse linear solves independently solve the unrounded Dirichlet system.
Observed error is checked against the residual times a rectangular discrete
barrier bound; iteration-limited results are not called converged.

Actual OpenCV `seamlessClone` NORMAL_CLONE and MIXED_CLONE runs are reported
separately. They use an RGB ROI implementation with different boundary,
solver and mixed-gradient details; sizable measured differences are preserved,
not described as equivalence. OpenCV is a comparison, not the integer oracle.
Reference URLs, successful fetch hashes and failed attempts are recorded in
`references.json`, including the original Perez et al. Poisson Image Editing
paper. No upstream implementation is copied.

Isolated synthesis passes Gowin `check`: 7x5 uses 877 LUT1..4, 141 MUX5,
3 MUX6, 304 FF and 36 RAM16SDP4; 32x32 uses 848 LUT1..4, 83 MUX5, 3 MUX6,
367 FF and 3 DPX9B. Both use zero DSP. Exact results and RTL hashes are in
the evidence JSON files. These are simulation and synthesis results, without
board acceptance or timing-signoff claims. Generated fixtures, binaries,
testbenches and netlists use automatically cleaned temporary directories.
