# Sparse matrix rows multiplied by a cached vector

`stream_sparse_matvec` loads one dense vector into local synchronous memory and
then multiplies a stream of sparse matrix rows by that vector. Each supplied
entry contains a column index and signed coefficient. One exact signed sum and
tag is returned per row, including empty rows. Unsorted and repeated columns
are accepted; every selected occurrence contributes separately.

This adds indexed dense-vector gather and reusable row processing beyond the
existing two-sparse-vector intersection dot products. Row boundaries are
explicit LAST markers. A CSR producer may translate its row pointers into these
markers; this core does not fetch row-pointer arrays or perform external DMA.

## Clock, configuration and transfers

All interfaces use the rising edge of one `clk`, with **no CE and no CDC**.
`rst` is synchronous high and cancels partial vector loading, the active row and
any pending result. All ready/valid outputs are suppressed while rst is high.
After reset a complete new vector must be supplied before any row can run.
Unreset RAM contents cannot be observed before full reload.

Transfer events are ordinary `valid && ready`. Sources hold valid and all
associated fields until accepted. CE-qualified legacy streams require a
semantics adapter before connection. There is one row in flight and one held
response, with preserved row order; rows do not overlap.

- `v_valid/v_ready/v_data` sequentially loads exactly VECTOR_LEN signed values,
  in column order 0 through VECTOR_LEN-1. It has no index or LAST. A partial
  load waits indefinitely; there is no timeout or automatic padding.
- Reset starts vector loading automatically. `reload_valid/reload_ready`
  requests another full load, retaining static parameters. Reload is accepted
  only between rows, after any previous result has been consumed. At that
  boundary reload has priority over a simultaneously offered first row entry.
  That row entry must remain held and belongs to the newly loaded vector.
- A reload request arriving mid-row waits without blocking the remaining
  entries of the current row. The requester holds reload_valid until accepted.
  Vector input is not accepted while computing a row or holding a result.
- `s_valid/s_ready` accepts `s_index,s_value,s_keep,s_last,s_tag` as one sparse
  row entry. `s_keep=0` excludes the entry but still carries the row boundary.
  An empty row is one excluded beat with s_last=1. Missing LAST keeps a row open.
  The tag on the **first accepted beat**, even an excluded one, labels the row.
- There is one `m_valid/m_ready` result per row; it implicitly completes that
  row, with no separate output LAST or matrix-end flag. The caller determines
  the number of rows in a matrix. All result fields and valid stay stable
  during backpressure. No next row or reload is accepted while a result waits.

No runtime column-count, numerical-format or capacity update is supported.
Parameters are fixed at elaboration.

## Numerical and error contract

| Parameter | Default | Legal range |
| --- | ---: | --- |
| `DATA_W` | 16 | 2..24; signed integer coefficient and vector width |
| `VECTOR_LEN` | 64 | 1..4096 |
| `MAX_TERMS` | 64 | 1..65535; selected-entry prefix capacity per row |
| `TAG_W` | 8 | 1..32; uninterpreted row tag |

Illegal parameters fail elaboration through an unresolved parameter-error
instance. Derived localparams are internal and cannot be user-overridden.
`INDEX_W=max(1,ceil(log2(VECTOR_LEN)))` and
`TERM_W=max(1,ceil(log2(MAX_TERMS+1)))`.

The first MAX_TERMS entries with s_keep=1 form the selected prefix. An invalid
index still occupies one position in that prefix, contributes zero and sets
`m_index_error`. Every selected index outside 0..VECTOR_LEN-1 sets that flag,
including one in the discarded tail. Invalid entries never read vector RAM.
Excluded entries ignore their index and coefficient completely.

`m_terms` is the number of entries in the selected prefix, **including invalid
indices**. Extra selected entries are consumed through LAST and set
`m_overflow`; they do not modify the prefix sum or count. This flag means
**capacity truncation**, not arithmetic overflow. It makes no whole-row accuracy
claim after truncation. The returned sum is exactly

```text
sum(coefficient[k] * vector[column[k]])
for the valid indices among the first MAX_TERMS selected entries
```

Vector and coefficient ports are signed two's-complement integers without
fractional bits. `ACC_W=2*DATA_W+ceil(log2(MAX_TERMS))`. Each full product fits
2*DATA_W signed bits, with absolute value at most 2^(2*DATA_W-2). At most
MAX_TERMS such products fit the accumulator's signed range, so no intermediate
rounding, wrap, saturation or arithmetic overflow occurs in the legal domain.
Duplicate columns count separately; cancellation and minimum-negative operands
are supported. Empty rows return zero with count and flags zero.

All response fields are meaningful only with m_valid. Reset requires the
upstream row and vector producers to restart their canceled transactions.

## Storage and service

Vector storage is VECTOR_LEN*DATA_W bits: 1024 bits at defaults, at most 98304
bits in the legal domain. Loading uses one sequential write port; gathering
uses one synchronous read port. Read/write states are mutually exclusive, so
the design does not depend on RAM same-address collision behavior. There is no
external memory interface, address protocol, bus error response, vendor
primitive, initialization file or external storage requirement.

The input-accept edge captures an index/coefficient, then one vector read, one
registered multiplication and one accumulation follow. An included valid
entry therefore has input II=4. Excluded, invalid or excess entries may be
consumed each clock. A final included valid entry produces response-valid
three clocks after acceptance; a final entry without arithmetic produces it
on the acceptance edge. Earliest response transfer is the next edge. After
that transfer a next row/reload may be accepted on the following edge. Full
vector loading can accept one value per clock. Unbounded input/output stalls
prevent any unconditional completion-time guarantee.

Qualitative default risk is **LOW** for storage and **MEDIUM** for arithmetic
mapping: one natural-width signed multiplier and one exact accumulator are
used, with product and accumulation on separate clocks. Larger vector lengths
increase storage linearly; the maximum may need several BRAMs. Actual RAM/DSP
inference, device fit, LUT/FF counts, frequency and power are **unmeasured**.
No combinational sparse matrix expansion or entire matrix storage is present.

## Offline use and evidence

`files.f` is the complete production dependency closure.
`examples/sparse_matvec_example.sv` exposes the default signed16 input and
signed38 result interfaces. No packages, include files, generated tables or
downloaded RTL are required. The repository Apache-2.0 LICENSE applies; source
and external-search decisions are in `SOURCES.md`.

From the repository root:

```text
python -B cores/acceleration/stream_sparse_matvec/sim/run.py
```

The Python standard-library runner prefers local OSS CAD Suite, supports
IVERILOG/VVP overrides and otherwise uses PATH. Each subprocess has a 15-second
limit. Missing tools, timeouts or failures write a non-PASS verification.json.
Task-specific temporary vectors and binaries are automatically removed. The
runner and TB contain everything required to regenerate the deterministic tests.
All delivered text uses LF so checked hashes match committed Git bytes.

Current status is **LINT_PASS + UNIT_SIM_PASS + HW_UNVERIFIED**. The example is
an **INTEGRATION_CANDIDATE**. `verification.json` contains source SHA-256,
actual commands and five finite parameter cases, including defaults, 24-bit
arithmetic, capacity one, vector length one/non-power-of-two, and tag32. The
independent Python reference uses arbitrary-precision multiplication over a
selected-entry list. Coverage includes 483 rows and 3317 supplied terms,
signed extrema, identity rows, duplicates, masks, empty rows, invalid columns,
capacity prefix overflow, changed tags, input gaps, six-cycle held results,
three vector epochs, reload held mid-row, and reset during vector load,
calculation or held output followed by clean reuse. The maximum parameter
profile is only compiled; four illegal parameters are rejected. Unlisted
inputs/parameter combinations are not proven. Synthesis, PnR, STA, hardware
and full regression were **NOT_RUN**.
