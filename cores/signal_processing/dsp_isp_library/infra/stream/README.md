# Synchronous Stream foundation

Status: isolated RTL, simulation and representative Gowin synthesis passed;
P&R, board and production integration **not yet accepted**.

## Interface contract

Both modules have `clk`, low-active **synchronous** `rst_n`, and `s_`/`m_`
`tdata`, `tuser`, `tlast`, `tvalid`, `tready` ports. Parameters `DATA_WIDTH>=1`
and `USER_WIDTH>=1` default to 16 and 1. Widths are unsigned opaque bit vectors;
no numerical conversion, quantization or floating-point model is applicable.
For pixels, `tuser[0]=SOF`, `tlast=EOL`; further user bits are opaque metadata.
The metadata and data always occupy the same stored beat. No optional clock enable.

An active transaction occurs on a rising edge with `rst_n && tvalid && tready`.
The source must hold valid, data and sidebands until accepted. Output valid never
waits for ready. All output fields hold while valid and stalled. Invalid payload
may be uninitialized and must not be inspected. Reset takes priority over transfers,
clears validity/control and discards **all** queued beats. RAM is not reset; old
RAM contents cannot produce valid output. Do not count transfers on a reset edge.
The reset assertion itself does not asynchronously change outputs.

| Module | Buffer capacity | No-stall latency | Steady II | Ready path |
|---|---:|---:|---:|---|
| `stream_elastic` | 1 beat | 1 cycle | 1 | combinational `!m_tvalid || m_tready` |
| `stream_sync_fifo`, RAM_DEPTH>=2 | RAM_DEPTH+1 | 2 cycles | 1 | RAM occupancy only |
| `stream_sync_fifo`, RAM_DEPTH=1 | 2 | 2 cycles | 2 | RAM occupancy only |

Latency counts rising edges from input transfer to earliest output transfer.
There is no fall-through. Full FIFO may reject an input on the same cycle that a
RAM entry is prefetched: ready intentionally has no combinational downstream path.
FIFO RAM_DEPTH is any positive integer (default 16), including non powers of two.
`level[$clog2(RAM_DEPTH+2)-1:0]` counts total stored beats including output slot.
There is no flush beyond reset. Backpressure is normal, not an overflow error.
Protocol-violating producers are not repaired; use an external protocol monitor.
Illegal static parameter values terminate simulation with `$fatal` and are outside
the synthesis support contract. There is no dynamic configuration interface.

FIFO uses synchronous memory read directly into the held output register. Read and
write pointers wrap explicitly at RAM_DEPTH. Empty inhibits reads; full inhibits
writes, so concurrent effective reads/writes have different addresses. This avoids
vendor-dependent same-address collision behavior. No large array clearing.
`ram_style` is a hint, **not evidence** that Gowin BSRAM was inferred; mapping must
be checked for each synthesis configuration. Tiny instances may become registers.

Use FIFO RAM_DEPTH>=2 to break a long ready chain. A series of elastic registers
does not break that chain. Stall latency is unbounded if the consumer never resumes;
queued beats drain in order when ready resumes, with synchronous-read startup.

## `stream_stats` — shared configuration/status/error-counter block

`stream_stats.v` is the passive statistics block that completes the INFRA-01
"shared configuration/status/error-counter" piece. It taps a channel boundary
without touching it: **every stream-facing terminal is an input**, so the gate
"no influence on the monitored channel" holds by construction and is exercised
in the testbench — the queue-model golden predicts every observed DUT output
while the tap is attached. Tap `s_*` on the observed block's ingress handshake
and `m_*` on its egress handshake; for a bare wire connect both groups to the
same signals (`accepted == emitted`, `source-stall == sink-stall` then).

Twelve 32-bit **saturating** counters, cleared by `rst_n` or a synchronous
`clr` pulse (clear has priority over counting; `clr` does not touch the
control register):

| cfg_addr | counter | condition per counted cycle |
|---:|---|---|
| 0 | accepted beats | `s_tvalid && s_tready` |
| 1 | emitted beats | `m_tvalid && m_tready` |
| 2 | source-stall cycles | `s_tvalid && !s_tready` |
| 3 | sink-stall cycles | `m_tvalid && !m_tready` |
| 4/5 | tlast-marked accepted/emitted beats | fire && `tlast` |
| 6/7 | tuser-nonzero accepted/emitted beats | fire && `tuser!=0` |
| 8 | error strobes | `err` input |
| 9 | counted cycles | `rst_n && enable` (utilization denominator) |
| 10/11 | idle cycles | `s_tready && !s_tvalid` / `m_tready && !m_tvalid` |
| 15 | control register | bit0 = counting enable (1 after reset), writable |
| other | read as zero | writes ignored |

Configuration/readout is one index-addressable port: `cfg_addr` selects the
register, `cfg_rdata` returns it registered (one cycle latency, samples
pre-edge values), `cfg_wdata`/`cfg_we` write index 15 only. Counting freezes
while enable is 0. Parameter `USER_WIDTH>=1` matches the tapped channel's
sideband width; illegal parameters terminate simulation with `$fatal`.

Reproduce (from repository root):

```sh
python cores/signal_processing/dsp_isp_library/infra/stream/test_stats.py
python cores/signal_processing/dsp_isp_library/infra/stream/synth_stats.py
```

`test_stats.py` drives randomized valid/ready traffic through real
`stream_sync_fifo` (depth 16/1/3) and `stream_elastic` instances plus a bare
wire, 1500 cycles per case with mid-stream resets, three `clr` pulses,
directed enable-off windows, error-strobe bursts, a white-box `c_accept`
preload to `0xFFFF_FFFE` proving saturation, a full readout-index sweep, and
four corruption rejections per case (data, sideband, counter readout, valid).
`USER_WIDTH=0` is rejected at elaboration time. Isolated `synth_gowin -noalu`
(default family, no `-family` flag) maps USER_WIDTH=1 to 869 LUT1-4 +
6 MUX2_LUT5 + 417 FF-class cells and USER_WIDTH=3 to 868 + 9 + 417, no memory
or DSP primitives. Same scope caveats as above: mapped cells only, not P&R.

Latest evidence at handoff for `stream_stats`:
- Simulation: `evidence/stats_20260926_151735_606139/summary.json` (5 cases,
  7500 traced cycles, all counters/readout checked per cycle, 20 corruption
  rejections, 1 illegal parameter).
- Synthesis: `evidence/synth_stats_20260926_151757_691421/summary.json`.

## Reuse review

Inspected `cores/acquisition/ads131m08/rtl/ads131m08_sample_fifo.v` and
`ads131m08_stream_adapter.v`: existing synchronous RAM mechanism is useful, but
their asynchronous reset, sample-event producer/drop policy and fixed ADC packet
format do not satisfy this contract. `cnn_systolic_20k/src/my_fifo.v` is dual-clock
with asynchronous reset. Those existing verified contracts remain untouched.
This directory provides small generic independent modules, reusing the established
synchronous-RAM approach instead of changing legacy behavior.

The new `goal.md` synchronous-reset contract takes priority over the legacy
asynchronous-reset/clk_en convention in `docs/IP_CORE_SOP.md`.

## Reproduce

From repository root:

```sh
python cores/signal_processing/dsp_isp_library/infra/stream/test_stream.py
```

The driver establishes OSS bin/lib PATH corresponding to `scripts/env.ps1`, calls
real local `iverilog -g2012 -Wall` and `vvp`, and creates a fresh timestamped
`evidence/` directory. No existing outputs are overwritten. It saves stimuli,
generated executable testbenches, full traces, compile/run logs, and summary with
source SHA-256. Failed runs remain present for diagnosis.

Independent Python queue model assigns transaction availability times without RAM
or pointers. A second transaction-only oracle checks conservation/order and held
output stability. Tests cover 15 width/depth configurations, 39,000 cycles, reset
interruptions, long backpressure, FIFO full/wrap, random producer gaps, random sink
ready, metadata and full-rate regions. Static illegal parameter tests verify rejection.
Each configuration injects data, order, count and sideband corruption into a copy
of the observed stream and proves the verifier rejects it. Seed is fixed per width.
Input vectors and expected outputs are generated before RTL executes; no DUT output
is used to construct expected values.

The initial failed run lacked the OSS DLL search path; it is preserved. The driver
now sets both bin and lib before spawning tools. Simulation is not physical timing
or CDC evidence; these modules are single-clock and are not CDC bridges.

## Isolated synthesis evidence

```sh
python cores/signal_processing/dsp_isp_library/infra/stream/synth_stream.py
```

Real `synth_gowin -family gw2a -noalu` results for DATA_WIDTH=16, USER_WIDTH=1:

| Configuration | LUT1–4 | MUX2_LUT5 | FF | DPX9B | DSP |
|---|---:|---:|---:|---:|---:|
| elastic | 3 | 0 | 19 | 0 | 0 |
| FIFO RAM_DEPTH=16 | 53 | 3 | 56 | 1 | 0 |
| FIFO RAM_DEPTH=256 | 88 | 7 | 72 | 1 | 0 |

Core logic counts exclude IBUF/OBUF and GND/VCC (raw cells are retained in JSON).
DPX9B is the actual Gowin memory primitive: synchronous RAM inference succeeded.
Counts are mapped synthesis only, not placed resource packing or 27 MHz timing
proof. No wrapper, chain, clock buffer or board logic is included in these counts.
All three Yosys checks reported zero problems; ABC's combinational-network note
is expected during combinational mapping. No latch or width/sign warning occurred.

Latest evidence at handoff:
- Simulation: `evidence/20260925_021944_226830/summary.json` (15 configurations,
  39,000 cycles, per-cycle level check, 60 corruption rejections, 3 illegal parameters).
- Synthesis: `evidence/synth_20260925_022055_314233/summary.json` with mapped JSON,
  exact scripts and logs. Source hashes identify the measured RTL.
