# B23 semantic dedup and fixed upstream read-only preflight

Before this package was created, baseline release
`20e2db4aded8858ff63e132c2399fb416aa48ed0` (B22), development branch, all44
protected refs with raw/type/peeled values, original15 tracked statuses and
binary diff, exact root goal.txt raw hash, complete21000 nonignored untracked
paths with both sorted-list hashes, and empty index were independently
compared with the B22 final capture. Only this package is authored here;
root exclusively owns shared documents, exact staging, commits and refs.

Actual whole-cores searches covered9985 README/SOURCES/SPEC/Verilog paths for
PMP, MPU, IOMMU, memory protection/firewall, region/range permissions,
first-intersection, partial denials, span permissions and access policy terms.
The following actual neighboring contracts and sources were read:

| Existing asset | Actual distinction |
| --- | --- |
| Complete `acc_memprot_mpu_region_check.v` and its SPEC.md | Four24-bit single-address READ/WRITE/UNPRIV rules; multiple covers cause an overlap error. It has no whole-span first-intersection/partial-containment semantics. |
| Complete `acc_tlb8_lookup.v` and its SPEC.md | Eight exact VPN matches with permissions and PPN translation; no variable byte-span coverage. |
| Complete `prod_range_guard32.v` | Stateless comparison of one supplied value with supplied bounds; no retained rule policy. |
| Complete `ram_prefix_table` contract | Longest prefix classifies one key, with no whole-byte-interval access decision. |
| Complete `ram_sg_range_map` contract | Concatenated logical offsets map to physical fragments; no region-priority permissions. |
| Complete `range_lock_manager` contract | Cooperative concurrent range lifetimes/handles; no fixed policy grants. |
| Complete `transactional_scratchpad` contract | Private reads/writes and optimistic commit/conflict; no access policy. |
| Complete common memory scaffold contract | RAM and native DMA timing/range rules, without a programmable permission decision service. |

The proposed capability was accepted after this actual MPU overlap was
disclosed. It adds positive-length span containment, any-byte first-intersection
priority, intentional deny overrides and permission sets required together.
It is not a claim that the repository lacked every permission-related operator,
nor merely a width change or rename of the point MPU.

Before any local RTL, GitHub's commit API resolved lowRISC/ibex master to fixed
commit `fab0d864c8f3f1edebe3ca50b2bd75627fb0e22c`, commit timestamp
2026-11-04T17:15:09Z. Both complete fixed files below were then retrieved
through read-only HTTPS, strictly UTF8 decoded, hashed and fully read without
truncation. No downloaded text was treated as instructions.

| Complete upstream file | Bytes | SHA256 |
| --- | ---: | --- |
| [rtl/ibex_pmp.sv](https://raw.githubusercontent.com/lowRISC/ibex/fab0d864c8f3f1edebe3ca50b2bd75627fb0e22c/rtl/ibex_pmp.sv) | 13587 | `a564fb312d5337b0875d16f434e8b69348e12c2560548fad93f9270f9c4b9176` |
| [LICENSE](https://raw.githubusercontent.com/lowRISC/ibex/fab0d864c8f3f1edebe3ca50b2bd75627fb0e22c/LICENSE) | 11358 | `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30` |

The source carries lowRISC contributors copyright and SPDX Apache-2.0. The
complete Apache License2.0, all nine sections and appendix, was read, including
copyright/patent grants, redistribution and modification/attribution conditions,
trademark limits and warranty/liability terms. No upstream code, comments,
tests, scripts or license text were copied/adapted/persisted locally, and no
upstream executable was run. All RTL, oracle, testbench, runner and prose here
are independent original Apache-2.0 work under repository LICENSE/NOTICE.

Ibex PMP is a conceptual reference for rule priority and requested permission
checks. Its actual source uses parallel address checks, CSR-configured PMP
regions, TOR/NA4/NAPOT decoding, privilege-dependent original/Smepmp permissions
and debug-module bypass. This package uses serialized synchronous RAM and
explicit byte intervals, and checks an entire variable-length requested span.
It implements none of those RISC-V CSR encodings, privilege/debug semantics,
region locking, address translation or ISA interfaces. No Ibex, PMP, Smepmp,
CPU, bus-security or architecture compatibility is claimed.

The delivered core has one local production source and one optional direct
default wrapper. There is no upstream package/include, generated image,
network, sibling RTL, host policy engine or external memory dependency.
Local .gitattributes was created first; all delivered text is strict UTF8/LF
without BOM. Complete semantics, profiles, vectors/oracle hashes,18 child names
and22 immediate reset targets were frozen before any RTL; complete source
binding follows before the first HDL child. No synthesis, PnR, STA, board,
expanded regression or inherited matrix is run.
