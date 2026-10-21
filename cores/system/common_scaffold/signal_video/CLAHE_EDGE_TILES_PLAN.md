# Runtime CLAHE edge-tile extension plan

Current runtime wrapper/helper reject odd tile dimensions and nondivisible frames.
The fixed-parameter, historically board-tested image core is outside this change.

- Use ceil(width/tile_width), ceil(height/tile_height), with nonzero safe divisors.
- Compute actual current tile width/height from remaining frame extent.
- Use actual area for histogram traversal, CDF division and total-count checks.
- Define doubled center(i)=2*i*nominal+actual_size(i)-1; interpolate between
  actual centers, with nearest-tile extension beyond outer centers.
- Permit positive tile dimensions including1; retain tile<=frame, <=256 tiles,
  strict clip capacity and all command/error/CE/backpressure contracts.
- Preserve every existing divisible-even numeric result.

Verification must include odd dividing tiles, one/both-axis remainder, residual
width/height1 and2, single tile and single-axis frames,256-tile capacity, random
and structured frames, actual-center boundary pixels, malformed markers,
configuration/tag capture, CE/backpressure and reset. The independent oracle
must enumerate rectangles and centers rather than copy RTL index shortcuts.

Status: design review only; implementation and verification pending.
