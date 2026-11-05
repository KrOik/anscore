# Provenance and functional gap review

New production RTL, example, testbench, reference/runner and documentation are
independently authored ANSCORE contributions under the repository Apache-2.0
LICENSE. No external RTL, Python source, coefficient table, generator or binary
was imported. All production dependencies are local and listed in `files.f`.

Before implementation, read-only external review on 2026-11-06 (Asia/Shanghai):

- Swabian Instruments' primary measurement API:
  https://www.swabianinstruments.com/static/documentation/TimeTagger/api/Measurements.html .
  Its StartStop/TimeDifferences descriptions establish two-channel time-difference
  measurement as an instrumentation function. This package streams raw
  clock-resolution intervals from the latest reference; it does not implement
  that product's histogram API, picosecond interpolator or complete pairing modes.
- Open-source LiteScope acquisition architecture:
  https://github.com/enjoy-digital/litescope/blob/master/litescope/core.py .
  The file-level BSD-2-Clause header and copyright were read before implementation.
- Upstream license:
  https://github.com/enjoy-digital/litescope/blob/master/LICENSE .
  BSD-2-Clause was inspected. No source, Migen/LiteX dependency, CDC block or
  upstream executable was adopted. The new RTL uses an independently specified
  synchronous event/session protocol rather than a triggered probe buffer.

Two guessed Swabian repository source/license endpoints and a linked histogram
documentation endpoint returned404. They supply no licensing or executable
evidence and no code was adopted from them. Only successful pages above support
this technical review.

Deep internal semantic searches covered acquisition, common_scaffold/dsp,
common_scaffold/peripherals, extended_library, stream_bus_library, DSP/ISP and
operator libraries, plus production source/README searches throughout cores.
Important existing assets were read rather than treated as absent:

| Existing asset | Existing behavior | New capability boundary |
| --- | --- | --- |
| system/stream_bus_library/rtl/sys_trigger_window.v | One-shot pre/post-trigger sample ring | Not duplicated; this package records event intervals |
| system/extended_library/src/ila_core.v | Configurable pretrigger probe capture/readback | Not duplicated; no waveform storage here |
| system/common_scaffold/peripherals/pulse_measurement | Continuous single-input high/low/period measurement with physical-time frontend | Separate reference/observation pulses and multi-stop reference epochs |
| system/stream_bus_library/rtl/sys_timestamp64.v | Timestamp a backpressured data transfer | Independent physical events continue and loss is counted under output stalls |
| system/stream_bus_library/rtl/sys_stream_metrics.v | Ordered input/output transaction latency observer | No FIFO-order transaction-pairing assumption; observations use latest reference |
| acceleration/operator_library quadrature_jitter | Quadrature event state/velocity estimate with supplied intervals | This package directly measures tick intervals between two event lines |

No mature module was modified. This package introduces no CDC implementation;
an upstream frontend must present synchronous event indications in this clock
domain. Pulse counting precision and clock scaling follow that frontend and the
actual reference clock; no analog performance claim is inherited.
