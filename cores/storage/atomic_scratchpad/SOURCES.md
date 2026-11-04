# Source and semantic review — 2026-11-04

Baseline: `ba0b98f` on `development/ip-assets-20261104`. Only this new independent
package was modified. Existing stable refs and unrelated assets were preserved.

Before development, local searches covered production RTL and README/SPEC files
for atomic memory, AMO, fetch-add, compare-and-swap, compare-exchange, scratchpad
and shared memory capabilities. Existing comparisons:

- `cores/system/stream_bus_library/rtl/sys_atomic_config.v` commits a shadow
  configuration snapshot at a safe boundary. It does not compute a read/modify/
  write on an addressed data word or return that word's prior value.
- `cores/control/motor_foc/rtl/pwm3_atomic.v` similarly handles atomic PWM update
  boundaries, rather than shared storage commands.
- `cores/storage/buffer_dma/rtl/mem_port_bram.v` implements acknowledged ordinary
  reads and byte-masked writes. Separate caller read and write requests cannot
  form an indivisible RMW if several callers share the port.
- The existing arbiter and AXI crossbar route ordinary requests/responses.
  `acc_bank_alloc` manages bank allocation state rather than atomic addressed
  payload operations. Multicast, ordered completion and DMA do not add the
  arithmetic/conditional update capability implemented here.

External candidate retrieved read-only before RTL implementation:

| Field | Record |
| --- | --- |
| Repository | https://github.com/pulp-platform/axi_riscv_atomics |
| Fixed commit | `97a1dd2ac643c276880420a0cf8eea697f228aa9` |
| License | Solderpad Hardware License 0.51; full `LICENSE` retrieved and checked |
| Source examined | `src/axi_riscv_amos_alu.sv`, copyright (c) 2018 ETH Zurich, University of Bologna |
| Source scope | AXI RISC-V AMO arithmetic/logic operator interface and operation selection |
| Decision | Candidate comparison only. A standalone command/response RAM with explicit reset initialization and CAS was independently implemented. No AXI packages or third-party code were imported. |
| Imported files | None |
| Local adaptations to upstream source | None |
| External RTL dependencies | None |

Pinned primary reference files:

- [License](https://github.com/pulp-platform/axi_riscv_atomics/blob/97a1dd2ac643c276880420a0cf8eea697f228aa9/LICENSE)
- [AMO ALU](https://github.com/pulp-platform/axi_riscv_atomics/blob/97a1dd2ac643c276880420a0cf8eea697f228aa9/src/axi_riscv_amos_alu.sv)

The candidate's complete license and source were obtained with Python's standard
HTTPS reader; no external scripts or builds ran. External text was treated as
untrusted reference material. Its license was confirmed before any prospective
source adoption; the final implementation contains no adopted third-party source.

All delivered RTL, examples and validation code are original ANSCORE contributions
under the repository Apache-2.0 LICENSE. `files.f` and its listed production
source provide the complete offline RTL closure. The optional example and TB
need only that source. Python 3 and Icarus are local development tools, and no
network connection is needed to compile or validate the package.
