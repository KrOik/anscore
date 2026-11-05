# Runtime canonical Huffman encoder codebook

`LINT_PASS + UNIT_SIM_PASS + HW_UNVERIFIED`. The finite Icarus checks are recorded in `check_results.json`; synthesis, placement/routing, STA, board operation and PPA measurements are NOT_RUN.

`canonical_huffman_table` accepts symbol code lengths, constructs a canonical prefix code in hardware, and answers encoder symbol-to-code queries. A successful BUILD atomically replaces the active table; an empty or oversubscribed staging table leaves the previous active table intact. Incomplete nonempty prefix codes are accepted. The caller supplies lengths, not final codewords. Frequency-to-length optimization, bit packing and decoding are outside this module.

## Interface and numerical contract

All ports use rising-edge `clk`. `rst` is synchronous active high and cancels any command/response, invalidates the active table, and starts a SYMBOLS-cycle staging clear. `c_ready` and `r_valid` are gated low during reset. There is no CE, CDC, implicit transaction end or external memory. Parameters are SYMBOLS=1..256 (default256), MAX_BITS=1..16 (default16), TAG_W=1..32 (default8). Unsupported profiles elaborate a named missing-module error.

Commands transfer on `c_valid && c_ready`; hold all command fields stable while blocked. Responses transfer on `r_valid && r_ready`; every response field is stable while blocked. Only one command owns the module, through response retirement, with no retirement-edge fallthrough. Configuration is captured on acceptance. BUILD blocks queries and LOADs until its response retires. Unbounded sink stalls imply no unconditional service deadline.

| Port | Width | Meaning |
| --- | ---: | --- |
| c_op | 2 | 0 LOAD, 1 BUILD, 2 QUERY, 3 CLEAR |
| c_symbol | 32 | Complete unsigned symbol index; validated before narrowing |
| c_length | 32 | Complete unsigned code length; LOAD accepts 0..MAX_BITS |
| c_tag | TAG_W | Opaque tag |
| r_op, r_tag | 2, TAG_W | Echoed command operation and tag |
| r_status | 3 | 0 OK, 1 BAD_SYMBOL, 2 BAD_LENGTH, 3 BAD_TREE, 4 NO_TABLE, 5 ABSENT |
| r_code | MAX_BITS | Unsigned, right-aligned canonical code; send its r_length bits MSB first |
| r_length | 32 | Exact unsigned code length; no fixed point or approximation |

LOAD modifies staging only; length0 removes a staging symbol. An out-of-range symbol takes precedence over a bad length, and neither error mutates staging. QUERY rejects an invalid index before checking active validity. A valid symbol returns NO_TABLE before the first successful BUILD or after CLEAR/reset, and ABSENT if its active length is0. BUILD/CLEAR ignore symbol/length fields, including all-ones values. Every non-QUERY response and every error has zero code and length.

Codewords are ordered first by ascending length, then by ascending symbol index. Within a length they are consecutive. The first code at the next length is twice the next unused code at the previous length. There is no bit reversal: protocol wrappers such as DEFLATE may need their own transmission ordering. All-ones codes and one-symbol incomplete trees are legal here; JPEG-specific reserved-code rules are not applied. BUILD rejects an entirely empty table and a codeword that exceeds its length's capacity. A successful table activates before its OK response is presented; retiring that response is not a second commit boundary.

## Architecture and timing

LOAD/QUERY produce valid response immediately after their acceptance edge. CLEAR produces a response after SYMBOLS staging-write cycles. After BUILD acceptance: SYMBOLS cycles initialize the inactive bank's presence lengths, MAX_BITS*(SYMBOLS+1) cycles scan symbols/advance lengths, then one cycle commits or rejects an empty tree. Thus successful BUILD latency is SYMBOLS + MAX_BITS*(SYMBOLS+1) + 1 cycles, excluding response retirement; oversubscription can terminate early. Initial/reset readiness follows SYMBOLS clearing cycles. Payload RAMs need no reset because only committed nonzero-length entries are readable. There is no read/write overlap between commands.

Two code/length banks and one staging-length bank use SYMBOLS*(2*MAX_BITS+3*ceil(log2(MAX_BITS+1))) logical payload bits: 12,032 bits at defaults. Small bounded counters drive a serial compare/increment/shift datapath; there are no multipliers or combinational unrolled codebook scans. Array reads are selected into response registers; device-specific BRAM mapping and timing have not been measured. Architecture risk is LOW at defaults and MEDIUM for target-specific RAM inference. No vendor primitive or external storage is required. Raising limits requires revisiting storage, indexing and BUILD latency rather than bypassing the parameter guard.

## Offline use and finite checks

Run both source lists from this package root: `files.f` contains the sole production source; `example/files.f` adds `huffman_byte_table`, a default-profile instantiation exposing the entire command interface. LOAD desired lengths, issue BUILD, then QUERY symbols; feed successful `(r_code,r_length)` pairs into a protocol-appropriate bit packer. Full source dependencies and the independent histogram/Kraft test oracle are local. Only Python standard library and Icarus are needed to rerun checks:

```powershell
python run_checks.py
```

The runner uses the repository OSS suite before PATH and limits each subprocess to20 seconds. It stops launching tools after any failure. The four tested `(SYMBOLS,MAX_BITS)` profiles are `(1,1),(8,4),(19,8),(256,16)`; they execute 11,367 checked commands including28 post-reset commands and45,463 stalled response cycles. Tests cover complete/incomplete tables, canonical symbol ties, empty/oversubscribed rejection, retention of active data after failed BUILD and uncommitted LOAD, zero/max lengths and the all-ones maximum16-bit codeword, high32-bit invalid indices/lengths, tags, absent symbols, reset during stalled response and BUILD, and recovery. This finite scope does not prove every parameter combination or generic AXI compatibility.

The first six invocations hit a broken Chocolatey PATH shim before HDL executed; `history/` preserves that receipt. Two subsequent successful finite runs are retained, including one after independent review fixes to missing-tool/timeout/stop handling. The latest ten invocations (two syntax checks, four TB compiles, four simulations) include the added maximum-codeword boundary and all passed; coverage is counted once. Compiler warnings about missing production-module timescale are retained and do not change functional timing. Temporary vectors and VVP images are reproducible and removed; raw tool stdout/stderr, vector digests and checked source digests remain in the result JSON.

Provenance and semantic reuse review: [SOURCES.md](SOURCES.md). All new implementation and test code is Apache-2.0 under the repository LICENSE.
