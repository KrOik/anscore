# Changelog

## 2026-09-14

- Added the Tang 20K board-level integration top for this IP:
  `projects/spi_lcd_e203_20k/src/top_adc_ip.v` (build `-Top adcip`) drives the
  verified voltmeter panel and UART reporter through the new narrow bridge
  `src/ads131m08_ip_host.v`, which performs the AXI-Lite boot sequence and
  paces stream beats into `adc_format`. `sim/tb_top_adc_ip.v` proves the init
  sweep, ID/config read-back and channel routing against the behavioural
  device model; OSS P&R for GW2A-18 passes at 114.86 MHz against the 27 MHz
  target with 3155/20736 LUT4. No IP RTL changed.

## 2026-09-13

- Added the harness control plane and standalone IP contract documents.
- Added a scalar GW2A 20K bring-up wrapper and corrected scalar CST names.
- Added build-input metadata and a versioned manifest that separates
  synthesis-only evidence from P&R evidence, records resource/timing gates,
  source hashes and artifact hashes, and rejects unconstrained IO.
- Removed FIFO memory `initial` clearing; reset and clear now invalidate data
  through the synchronous pointers, keeping storage initialization out of the
  functional contract.
- Defined the pad-wrapper LED contract and removed undriven status nets from
  the 25K wrapper.
- Expanded parameter guards and boundary checks for OSR, power mode, scheduler
  mode, address width, clock/divider and FIFO limits.
- Consolidated sample-counter and status-snapshot updates onto single
  sequential owners after formal preparation exposed multiple-driver netlist
  warnings; the AXI/FIFO/stream behavior remains covered by regression.
- Added an ADS-specific formal boundary harness. The current OSS run is a
  12-cycle bounded check; unbounded induction remains open.
- Made `CTRL.W3` clear the software-visible IRQ and unmapped-write latches,
  added regression coverage for that contract, and clarified that unmapped
  reads are side-effect-free diagnostics.
- Closed the minimal AXI-Lite compatibility contract after documenting and
  regression-locking its `OKAY` and ignored-`WSTRB` behavior; strict byte writes
  remain a future interface revision.
- Added a documentation/release audit for repository paths, register offsets,
  build source lists, formal scope and reference-only constraints.
- Expanded the parameter boundary regression to 10 legal and 10 illegal cases.
- Split register/status ownership and FIFO/AXI-Stream ownership from the top
  level into `ads131m08_regfile.v` and `ads131m08_stream_adapter.v`; the
  original top-level ports and register offsets remain unchanged.
- Re-ran the 20K scalar P&R evidence after the split: 436 LUT4, 166 ALU,
  188 DFF, 0 DSP, 287.94 MHz Fmax at a 27 MHz target, zero route errors and
  zero unconstrained IO.
- Added an isolated FIFO inference probe for Gowin families; it records
  the mapped block-memory primitive count for GW2A/GW5A at depths 64 and 512.
  H-007 remains open for evidence across other vendor flows.
- Extended scan and build manifests with Python, PowerShell and formal-tool
  availability/version records.
- Added a bounded VVP timeout and optional quiet output to the ADS regression,
  plus an expected-failure compiler fixture for the unified quality gate.
- Preserved existing simulation contracts; no AXI or RTL behavior change was
  intentionally introduced in the reusable IP.
- Corrected the unmapped-access sticky error to the documented `ERR[18]` bit;
  this is an explicit compatibility bug fix covered by the AXI regression.
