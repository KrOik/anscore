# Bounded fixed-point LDLT matrix factorization

`fixedpoint_ldlt` factors a runtime symmetric matrix into a unit lower-triangular
factor `L` and diagonal factor `D`, using the unpivoted recurrence associated
with `A ~= L*D*transpose(L)`. It accepts the lower triangle and infers symmetry;
no upper-triangle inputs exist. Fixed-point quantization is explicitly defined
below. Factors are released only after every pivot and factor passed its checks.
An arithmetic failure produces one marker and no partial factors.

This is a matrix factorization primitive, distinct from the existing exact
`linear_solve2x2`, eigensolver, adaptive filters and scalar division. It does not
perform matrix inversion, triangular solves or factorization with pivoting.

Status: **LINT_PASS + UNIT_SIM_PASS + HW_UNVERIFIED** for the finite profiles
recorded in `reports/*/results.json`. LINT_PASS here means Icarus syntax checking;
no synthesis, PnR, STA, board test, device-fit or PPA measurement was performed.

## Numeric contract

Every matrix element and output factor is a signed two's-complement integer of
`DATA_W` bits interpreted with `FRAC` fractional bits. The implicit diagonal of
`L` is exactly `1<<FRAC`; it is not transmitted. All input bit patterns are legal,
but success requires each computed quantized pivot to be positive and every
computed factor to fit the signed output width. There is no clipping, saturation,
tolerance, exceptional bit pattern, divide-by-zero output or floating-point math.

Let `Q=2^FRAC`, and let capital letters below denote stored integers. For each
column `k`, processing its diagonal followed by rows `i=k+1..n-1`:

```text
R(i,k) = A(i,k)*Q^2 - sum[j=0..k-1](L(i,j)*L(k,j)*D(j))
D(k)   = floor(R(k,k)/Q^2)
L(i,k) = trunc_toward_zero(R(i,k)/(D(k)*Q)), i>k
```

The complete dot sum is retained before the single diagonal quantization or
off-diagonal division. Negative quotients truncate toward zero, whereas diagonal
right shift floors toward minus infinity. These are different rounding rules.
The result is the recurrence above, not a promise of exact reconstruction of an
arbitrary real matrix. A mathematically positive-definite matrix may be rejected
after quantization makes a pivot zero/nonpositive or a factor unrepresentable.
No regularization or near-singular threshold is inserted. No interchange of
rows/columns occurs, and negative/zero pivots are rejected rather than supported
as an indefinite or semidefinite factorization.

Two-factor and three-factor products retain `2*DATA_W` and `3*DATA_W` signed
bits. The residual/divider width is
`ACC_W=3*DATA_W+ceil(log2(MAX_N+1))+2`. With at most `MAX_N-1` triple products,
each term's magnitude is at most `2^(3*(DATA_W-1))`; the extended original
term and sum fit this accumulator. Values are sign-extended before shifts and
subtractions. The positive stored pivot is widened before multiplication by Q.
All arithmetic preceding the documented quantization is exact in the supported
parameter domain.

## Parameters and interface

| Parameter | Range | Default |
| --- | --- | --- |
| MAX_N | 1..8 | 4 |
| DATA_W | 4..16 | 16 |
| FRAC | 1..DATA_W-2 | 8 |
| TAG_W | 1..32 | 8 |

Unsupported parameter profiles fail elaboration through a named missing module.
The maximum dimension is a storage bound; every runtime dimension 1..MAX_N is
accepted. Clock-enable and CDC are absent. All transfers use one rising-edge
`clk`; `rst` is synchronous active high. Reset cancels loads, calculations,
division and any pending result at the reset edge. It returns control directly
to IDLE. Payload arrays need no reset because the next command loads every
matrix entry it will read, and calculation writes factors before any use.
Reset dominates every transfer.

| Port | Width | Meaning |
| --- | --- | --- |
| c_valid / c_ready | 1 each | Command transfers when both high and reset low |
| c_dimension | 32 | Full unsigned dimension, validated before narrowing |
| c_tag | TAG_W | Captured opaque transaction tag |
| s_valid / s_ready | 1 each | Matrix input transfers when both high and reset low |
| s_data | DATA_W signed | Matrix element in fixed-point format above |
| m_valid / m_ready | 1 each | Result transfers when both high and reset low |
| m_status | 2 | 0 OK, 1 BAD_DIMENSION, 2 NONPOSITIVE_PIVOT, 3 OVERFLOW |
| m_row / m_column | 32 each | Zero-based matrix/factor coordinates |
| m_data | DATA_W signed | D on diagonal records; L on strictly lower records |
| m_diagonal | 1 | One for D records, zero for strictly lower L records |
| m_last | 1 | Last record of this transaction, including a sole error marker |
| m_tag | TAG_W | Captured command tag echoed on every result |

After a valid command, send exactly `n*(n+1)/2` input samples in row-major lower
triangle order: `(0,0),(1,0),(1,1),(2,0),...,(n-1,n-1)`. Input last is implicit
in that count. Producers can pause arbitrarily; only handshakes advance counts.
The command parameters/tag are captured only at command acceptance and may change
afterward. There is one transaction owner through final-result retirement:
`c_ready` stays low during loading, calculation and results; `s_ready` is high
only during loading. No samples are accepted on the command edge, and there is
no final-result/command fallthrough.

On success, the same row-major lower-triangle order returns D at diagonal
coordinates and L elsewhere, with status zero on every record. For dimension1,
the sole record is `D(0)` and last. Under output backpressure, `m_valid` and every
result bit remain stable. Upstream sources must likewise hold every valid input
field while blocked. No external memory interface or memory error channel exists.

Dimensions zero, greater than MAX_N, and high-bit alias candidates produce one
BAD_DIMENSION marker without accepting samples. Its row/column/data/diagonal are
zero. Arithmetic errors identify the failing `(i,k)` coordinate; data is zero,
and diagonal is one for a pivot failure or zero for an L overflow. A nonpositive
quantized pivot takes precedence over pivot-width overflow. All error markers
have last one and the captured tag. A successful factor set is not retained as a
queryable table after its stream retires; a fresh command always loads a matrix.

## Architecture, resource risk and latency

Matrices/factors use two bounded `MAX_N^2` arrays plus `MAX_N` diagonal entries:
`(2*MAX_N^2+MAX_N)*DATA_W` logical payload bits, 576 at defaults and 2176 at
the maximum. Sequential row/column counters avoid a combinational factorization
network. A registered two-factor product followed by a registered triple product
provides two multiplication operators, not an implicitly shared multiplier.
The local accumulator sums one triple product over four clocks per prior column.
An unchanged existing signed restoring divider is shared by all off-diagonal
entries. No square root or vendor primitive is needed.

Array access is asynchronous into registers; large target-specific MUXes or
register storage may result, so BRAM inference is not claimed. Qualitative
architecture risk is **MEDIUM**, reflecting the wide serial divider, two product
operators, matrix selectors and unmeasured target mapping. No frequency, physical
DSP count, power or target fit is inferred from these logical counts.

Loading accepts up to one sample per clock. After the final input handshake, a
successful diagonal entry in column k costs `3+4*k` clocks; an off-diagonal
entry costs `ACC_W+5+4*k`. One final clock presents the first output. Thus:

```text
first_valid_latency = 1 + sum[k=0..n-1](3+4*k)
                       + sum[k=0..n-1]((n-k-1)*(ACC_W+5+4*k))
```

At default MAX_N=4/DATA_W=16 this is 401 clocks for dimension4. At the maximum
MAX_N=8/DATA_W=16 it is 2013 clocks for dimension8. Errors may terminate earlier.
After an output is retired, the next output becomes valid one clock later and
can be accepted on the following clock. Arbitrary input/output stalls prevent an
unconditional transaction deadline. Error responses from invalid commands are
available immediately after their acceptance edge.

## Offline source closure and checks

Both `files.f` and `example/files.f` resolve from this package root. Production
depends on this RTL plus the unchanged repository modules:

- `../../image_processing/grayscale_anisotropic_diffusion/rtl/deps/integer_divider.v`
- `rtl/deps/signed_divider.v`

These are exact-byte aliases of the previously tested original acceleration
sources, not new arithmetic implementations. The existing committed canonical
integer path avoids duplicate declarations in the cumulative snapshot, and the
signed wrapper is copied unchanged into this package. Original untracked files
are not modified or made delivery dependencies. Their pinned SHA256 values and
original-to-delivered mappings are in `QUALIFICATION.json` and `SOURCES.md`.
Prior tested source lists and exact source snapshots remain in their original
report directories. Current syntax-only checks prove the final list resolution;
the byte-identical unit-test source closure retains the finite numerical evidence.
No numerical model or simulation was rerun merely for relocation.

Their exact bytes are included in every test source manifest/snapshot. Include
all three source files in an offline project; none is generated. The example
`ldlt_matrix4` exposes the default interface and can connect to a row-major
lower-triangle producer and factor consumer using ordinary ready/valid. It does
not adapt CE-qualified streams. See `SOURCES.md` for provenance and semantic review.

```text
python run_tests.py
# For source-list closure checking alone:
python run_tests.py --syntax-only
```

The standard-library runner uses absolute local OSS suite executable paths before
PATH fallback, places suite bin/lib first on PATH, and has a 20-second child-tree
watchdog. It stops launching after failures, missing dependencies or timeouts.
Each timestamped report directory retains exact input source snapshots before
execution, source/tool hashes, vector files/digests, raw stdout/stderr and status.
The package's `.gitattributes` preserves file bytes, including LF line endings,
through Git staging. Temporary VVPs are not delivery dependencies.

The final four profiles `(MAX_N,DATA_W,FRAC)` are `(1,4,1),(3,8,3),(4,16,8),
(8,16,14)`: smallest storage/data width, nonpower-of-two capacity, defaults, and
maximum capacity/width/fraction. The final run contains two syntax checks, four
TB compilations and four finite simulations. Each simulation compares complete
result streams against an independent exact-rational symmetric rank-one update
oracle; the RTL instead recomputes integer dot sums. Tests include known-factor
matrices, signed off-diagonal values, small quantized pivots, extreme inputs,
negative/zero pivots, positive and negative factor overflow, invalid high-bit
dimensions, input gaps, command-field mutation, output stalls, partial-load reset,
held-output cancellation, active shared-divider reset and recovery. The N=1
profile skips the inapplicable divider reset. Every source snapshot and historical
run remains distinct; earlier evidence is not silently relabeled for changed
profiles. There have been no observed RTL or TB failures in package checks.
