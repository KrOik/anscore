# Quantized grayscale anisotropic diffusion

This core computes a complete four-neighbor Perona鈥揗alik rational-conductance diffusion from actual unsigned8 pixels. Every iteration reads a complete old frame and writes a separate new frame. It adds image-state evolution beyond existing bilateral/Wiener/Retinex and quantization-error diffusion assets. No host gradients, coefficients, intermediate frames or results are supplied.

**SOURCE_ONLY / NOT_RUN / HW_UNVERIFIED.** No preparation, reference execution, compiler, simulation, synthesis, PnR, STA, board test or inherited matrix has run. verification.json records this boundary. The author seal precedes a separately approved single preparation. The prepared SOURCE_SEAL and another exact approval must precede HDL execution.

## Frozen arithmetic

WIDTH/HEIGHT each1..32 (default16), TAG_W1..32 (default8). Snapshot unsigned8 K1..255, unsigned5 I0..16 and tag on the first accepted pixel. I0 is identity. Initial U[p]=256*pixel[p] is unsigned16 UQ8.8.

```text
D[a] = floor(256*K*K/(K*K+a*a)), a=0..255

d_j = U_old[neighbor_j]-U_old[p]          # N,S,W,E
index_j = floor((abs(d_j)+128)/256)
S = sum(d_j*D[index_j])
step = sign(S)*floor((abs(S)+1024)/2048)
U_new[p] = U_old[p]+step
pixel_out[p] = floor((U_final[p]+128)/256)
```

Out-of-image neighbors replicate the center. Time step is fixed1/8. D floors, index/final pixel round half upward, signed update rounds half away from zero. There is no intervening flux rounding. This discrete variant is not a continuous PDE exact solution or bit-identical OpenCV/ITK implementation. Fixed I does not claim convergence, exact total-intensity conservation or measured quality gains.

D is unsigned9 including D[0]=256. U stays0..65280: effective weights D/2048 sum to at most1/2, making the unrounded update a convex combination; rounding between integer endpoints preserves local min/max. abs(d)<=65280, so index<=255. d is signed17; table numerator unsigned24/denominator unsigned17; product signed25; four-flux sum signed27. Expand the signed step before adding U. No silent saturation repairs an arithmetic error. Constant frames and1x1 remain exact. BOUNDARY_CERTIFICATES.json contains hand-derived signed-half and constant-fresh cases.

## Ports and ownership

One rising-edge clock, synchronous active-high rst, ordinary ready/valid; no CE/CDC. Accept only valid&&ready. Hold all source fields while stalled. Supply exactly N=WIDTH*HEIGHT row-major pixels. SOF is true only at index0, EOL at each final column, LAST only at N-1. Markers do not restart or shorten capture. Later live K/I/tag are ignored.

| Port | Meaning |
|---|---|
| s_pixel[7:0],s_k[7:0],s_iterations[4:0] | Actual pixel and first-pixel configuration |
| s_sof,s_eol,s_last,s_tag[TAG_W-1:0] | Markers and owning tag |
| m_pixel[7:0],m_value_q8[15:0] | Rounded output and retained final UQ8.8 state |
| m_x,m_y | Coordinates, max(1,clog2(W/H)) bits |
| m_sof,m_eol,m_last,m_keep | Canonical raster markers and payload validity |
| m_errors[4:0],m_tag | Sticky frame bitmap and first tag |

Errors0/1/2 mean SOF/EOL/LAST mismatch; bit3 K0; bit4 I>16. Drain all N inputs even on error. Any error emits one tuple with x/y/pixel/Q8/SOF/EOL=0, LAST1, keep0, owning tag and complete errors; no table/image prefix is produced. Success emits N keep1/error0 tuples. All fields hold while m_valid&&!m_ready. No next input transfers during work or held output. After final retirement, capture is eligible at the next rising edge.

Reset gates ready/valid low and cancels capture, child division, image work and pending outputs at its edge. RAM/read payloads are not reset. Fresh capture covers A, full table build precedes table read, and a destination bank is not read before its complete write/swap. No unconditional bound applies to unlimited input gaps/output backpressure.

## Architecture, timing and reuse

Two synchronous16-bit frame banks, one synchronous256x9 table, one registered16x9 multiplier and unchanged integer_divider W24. Neighbor reads are serialized; there are no asynchronous frame reads or multi-read RAM assumptions. Build D once, reducing divisions from4NI to256; I0 skips the table. K虏/table-index虏/flux share one multiplication expression.

From final accepted input edge to first visible m_valid, in clock periods:

```text
error: 1
valid I0: 3
valid I>0: 7429 + I*(37*N+1)
```

256 table entries each29 periods, CHECK1, K-square/take2 and final read/take2 give7429. Each iteration uses37N+1 periods. Default N256/I4 tail45321; maximum N1024/I16 tail613653. Earliest retirement is one edge later. Capture II1 and always-ready output II3 are distinct from complete-frame service; no overlap is implemented. These are source-derived counts, not execution evidence or achieved-frequency claims.

Logical RAM32N+2304 bits:10496 default/35072 maximum. Wrapper scalar/read/output declarations are274+2AW+3XW+2YW+2TAG_W bits:326/383. W24 divider adds129 bits, combined455/512. These are declaration budgets, not mapped LUT/FF/BRAM/DSP. COST.md describes risks.

Actual unchanged dependency: cores/acceleration/integer_divider/rtl/integer_divider.v SHA256 e09b6e9501a02fbcb0a89be50b5a0b787c71e9180b934b32d446601a299c5f6c. It is referenced directly, never copied/modified. No old numerical/formal/physical matrix is rerun or promoted.

## Explicit file-list base

Both files.f and example/files.f use **repository-root-relative** entries, base D:/anscore. Do not resolve them relative to package/example. example/files.f explicitly lists the two production sources and all-port diffusion16 wrapper, without nested -f. Authorized runner argv compile tested local source copies plus the absolute hash-bound dependency.

## Fixed future gates

CASE_TABLE fixes16 named cases in five profiles1x1/1x5/5x1/4x3/32x32. Two main stall modes yield32 frames,2198 output records,33330 Q8-write checks,114 iteration rows,18 table rows. Maximum p4 has only its original main case, no reset. Only p3 has four reachable reset predicates: partial capture, live table division, nonzero pending flux, held output. Assert reset at the observed predicate, offer through three reset-high edges, then compute a complete constant fresh I2 frame:48 fresh outputs/96 fresh writes total. No Cartesian enumeration, random search or predicate expansion.

The independent Fraction reference uses immutable old-frame snapshots. TB checks every table value, every Q8 write, bank ordering, all output fields, exact first-valid tail, held stability, config/tag ownership and full fresh recovery. fscanf uses scalar temporaries for multidimensional destinations; string dispatch uses if/else. Validators compare complete ordered raw streams to stored JSON. The stored child checks hashes, JSON/text tuples, shape and hand certificates without calling expected, pixels_for or Fraction. None have run.

PREPARATION_PLAN allows one authorized Python payload, kill-on-close Job20s. After independent source review, root must approve AUTHOR_SEAL/PREPARATION_PLAN/child_argv and two independent review hashes, max_invocations1. Invoke fixed Python -B prepare_gate.py --approval path. It exclusively creates an initial receipt, lock, fixtures, raw streams and SOURCE_SEAL. Captured approval/author/plan/review and tool hashes are checked around the child and seal; any post-creation exception persists FAILED_STOPPED, retains partial bytes and archives them without retry. This is not current execution authorization.

TEST_PLAN fixes26 children: stored hashes/shape/tuples/certificates, version, core/example lint, five fresh compiles, ten mains, one p3 reset and six named rejects. Each tree hard20s, first failure stops with remaining NOT_RUN. Independent post-preparation review and exact root SOURCE_SEAL/TEST_PLAN/children/max_invocations1 approval precede run_tests.py. PATH is bin then lib. Captured source/author/plan/approval/review hashes, dependencies, tools/eight DLL/six VPI/full39 lib/ivl files, exact tested copies and exact generated VVPs are guarded before and after every child; each compile binds all six embedded VPI paths. Initial receipt/all26 NOT_RUN slots precede copy setup. Every post-creation failure retains and archives partial copies/raw/VVP bytes. No automatic retry, shrinking, new matrix, larger limit or successful artifact deletion. No execution result is claimed.

Compiler closure additionally freezes the exact39-file lib/ivl installation inventory, including ivl.exe/ivlpp.exe, all target .conf/.tgt and installed includes. All39 hashes and static PE import names for iverilog/ivl/ivlpp/null.tgt/vvp.tgt are recorded in DEPENDENCIES; guards reject added/missing/changed install files. No executable/target was loaded or run.
