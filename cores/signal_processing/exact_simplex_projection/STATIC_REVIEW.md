# Author-stage static review

Scope: only this new package. No Git, shared document, old package, numerical
preparation, oracle execution, HDL compiler, HDL simulator, synthesis, PnR, STA
or board operation was performed during authoring.

Observed static checks: Python's `ast.parse` read all four Python source files;
JSON parsing read the 23-child fixed TEST_PLAN; no package module was imported
or executed. Source/plan hashing is permitted input sealing, not numeric evidence.
These checks do not establish Verilog elaboration or simulated behavior.

Manual RTL review:

- First accepted beat initializes sum from zero and captures unsigned mass/tag;
  the Nth accepted beat enters INITIALIZE. N1 follows the same path without an
  out-of-range counter value. Partial input state advances only on handshake.
- A complete vector is written before READ. Reads are clocked and mutually
  exclusive with writes. RAM and arithmetic payload have no reset dependency;
  fresh input plus INITIALIZE overwrite every subsequently live field.
- PASS_READ registers RAM data; PASS_MULT registers the full natural product;
  PASS_CHECK consumes that product with fixed k/T. The last survivor update has
  a complete edge before PASS_END consumes sum/count. Indexed bitmap mutation
  affects only the current element and never changes the current pass threshold.
- The zero prefix on k, zero extension of M, sign extension of sample/product,
  accumulator width and final numerator slice match the README bounds. No
  threshold divide, implicit signed-M interpretation or intermediate rounding
  occurs. Count/round widths include N and index width handles N1.
- HOLD leaves every externally valid payload field unchanged under a stall.
  Last retirement switches to LOAD and index zero; input ready becomes eligible
  for the following edge. Reset dominates both memory and arithmetic updates.
- One selected wide adder/subtractor, one multiplication expression and one
  signed product/threshold comparator are shared across phases. The bitmap and
  control comparisons are separate small logic; physical resource mapping is
  deliberately unclaimed. The derivation includes RAM and pass boundaries.

Manual verification review:

- Explicit N1=12 and N3=32 named pairs replaced the unexecuted Cartesian authoring
  proposal before freezing. Default/maximum retain 28 fixed named pairs each.
  Every planned pair and reset owner is fixed in source; preparation failure
  cannot trigger a substitute, reseed or extra input.
- Sorting/prefix is the expected-value oracle; exact KKT/mass/nonnegativity and
  small mathematical-support checks certify it. The separate deletion scheduler
  supplies only live reset predicates and checks its final k/T against that oracle.
- Reset predicates include state/index/retired prefix and every phase-live
  arithmetic field. Non-live values are masked and logged canonically as zero.
  The TB verifies actual registered predicates, holds next-frame data behind a
  valid last, aborts each owner, and retires every output of a distinct fresh frame.
- Two fixture slots permit queued input without overwriting the active owner's
  expected data. Source fields remain stable on blocked input; later-beat metadata
  intentionally differs. Output comparison runs while stalled as well as retired.
- The immutable TEST_PLAN precedes preparation. Preparation and source-seal approval
  are separate gates. The runner reads certificates instead of importing the oracle.
  A Windows Job contains a suspended child before resume; a terminal 20-second
  tree deadline or first discrepancy stops later children and preserves evidence.

Result: author-stage review only, RTL_CANDIDATE / HW_UNVERIFIED. Planned coverage,
latency bounds and exact math are not described as executed PASS results.
