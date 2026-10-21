# Change log

## Development snapshot 2026-10-21

- Added four-lane calibrated quadrature integration using canonical DDS and
  shared CORDIC, explicit timestamp/cadence/error checks and held results.
- Added fixed-clock virtual ADC, finite replay ownership, timeout/overflow
  abort and recovery preserving the timestamp epoch across soft abort.
- Added canonical atomic configuration adapter and transport-neutral CSR
  control with one pending commit and explicit completion acknowledgement.
- Added supplementary25K UART/probe binding, frozen source/ROM build and
  fingerprinted transport-neutral host numerical verification.
- Added independent numerical, error/recovery, backpressure, atomic queue,
  serial-top and host negative tests. Preserved failed attempts in artifacts.
- Full25K build and physical runtime/LA acceptance remain open; no release
  or analog measurement claim. License audit remains open.
