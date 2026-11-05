# Source-only author review

Status: RTL_CANDIDATE / HW_UNVERIFIED. This is the author's static review,
not independent acceptance. Preparation, oracle evaluation, HDL lint/compile,
simulation, synthesis, PnR, STA and board execution remain NOT_RUN.

The review used source reading, custom Python standard-library AST/JSON/text
parsing and byte hashing only. No package module was imported and no package
function or entrypoint was executed. No prepared fixtures, source seal, execution
evidence, VVP, bytecode cache or numerical result was produced.

## Interface and storage reasoning

The ordinary ready/valid command interface has one owner through RESULT or
RANGE END retirement. All response registers update only when constructing a
new response; OUT without ready keeps every response field and ownership.
Only IDLE advertises command ready, so retirement cannot also accept a command.
Reset masks both public transfer enables, resets RAM response control and empties
logical count. Physical rows beyond count are never read.

Each RAM request state advances to its own wait state only on request ready.
Wait states consume the RAM response before the next request is offered.
Write-response old data is ignored. The canonical shared RAM is referenced
directly and its bytes remain unchanged; clk_en is tied high and all byte strobes
are set. The only local row buffer carries either a search row or a moving row.

Manual state tracing covered empty/full dispatch, replacement at full, insertion
at first/middle/last positions, deletion at first/middle/last positions, missing
keys, lower-bound exhaustion, equal/invalid/empty range and reset cancellation.
The lower-bound invariant is 0<=lo<=hi<=count<=CAPACITY; midpoint uses a widened
sum. A non-full insertion shifts high-to-low, writing at most old count<CAPACITY.
Deletion shifts low-to-high and commits count-1 after the final write response.
CAPACITY=1 cannot reach either shift path. Count/search/index/cursor width can
represent CAPACITY; a RAM address is consumed only when its row index is below
CAPACITY. Unsigned extended subtraction supplies key order and equality without
sentinel values, signed casts, scaling, rounding or tolerance.

Default storage is 32*64=2048 logical RAM bits. The explicit source register
inventory is 352 bits including shared RAM response registers; it is not a
measured FF count. There is one full-key subtract/zero test and no multiply,
CAM, pointer RAM or external memory. Actual mapping, timing and power are unknown.

## Testbench and future runner reasoning

The TB offers inputs at falling edges and checks transfers at rising edges.
Scalar fscanf destinations avoid multidimensional-array VPI writes. Its output
monitor covers all response fields during stalls, including RANGE END. Expected
records fit at most CAPACITY ROWs plus one END. Maximum-width key/value display
uses unsigned values. Every named reset probe selects a concrete internal state;
next_offer holds a real PUT behind a stalled ROW across asserted reset and checks
its first later handshake. Ordinary reset jobs withdraw their dummy offer before
reset release. Fresh programs start after the reset boundary.

Future preparation and execution have separate root gates. Preparation creates
exclusive output, evaluates only the frozen named programs and cannot be called
by any HDL child. Stored validation checks stored bytes/shape without rerunning
the oracle. Child raw streams are saved before validation; the first failure
stops later slots, preserves partial sources/raw/artifacts and archives them.
Each process tree has a 20-second deadline, suspended Windows creation and Job
assignment before resume. No retry, seed expansion or Cartesian enumeration is
present. Source/copy/dependency/tool/artifact hashes are guarded around children.

## Completed static checks

- All four Python source files parsed with ast.parse; no imports or calls from
  these files were evaluated.
- Every authored JSON file parsed. RAW_INPUTS has three unique-name literal
  programs: p0=(1,1,1),19 commands; p1=(5,9,7),35; p2=(32,32,32),56.
  Literal operation/key/value/high fields are within their declared widths.
- TEST_PLAN has 22 unique children: one stored check, two lint/example compiles,
  three fresh VVP compiles, nine simulations and seven named parameter rejects.
  The fixed main modes are 0/1 and reset job counts are 7/10/10, totaling 27.
- Both source lists resolve from the package directory. The example exposes
  every functional port with the documented default widths.
- All 20 author files before this review used LF bytes. Shared RAM, baseline
  B28 manifest, B29 start protection and candidate-brief hashes were checked.
- process_tree.py is byte-identical to the existing internal reviewed helper;
  SHA256 d43f929de708d66fcf8218c902b4d7c8bc61c6bb2984ee6a1f6d8ca1bd45d011.
  One preliminary metadata assertion mistyped its expected digest; direct byte
  equality and the corrected digest resolved that assertion without source edits.
- All recorded tool binaries, 20 static PE-closure files and two backend configs
  matched TOOLCHAIN.json. Actual dynamic loaded-module tracing is NOT_RUN.
- No prepared/, preparation_evidence/, evidence/, SOURCE_SEAL.json or
  __pycache__/ exists in this source-only package.

The package is frozen by AUTHOR_INPUTS.json after this record. Independent review
and an exact root preparation gate are still required before any execution.
