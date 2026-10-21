# Asynchronous Stream FIFO / CDC bridge (INFRA-03)

Status: isolated RTL + bit-exact simulation + independent transaction oracle
passed; isolated `synth_gowin` mapping recorded. P&R, physical CDC timing and
board evidence are **not** claimed. See `evidence/` for logs.

## Interfaces

Both modules implement the repo stream contract (`tdata/tvalid/tready`,
rising-edge transfers, stable payload under stall, source `tvalid` never waits
for `tready`) with two independent clocks. Resets are **synchronous
active-low** per domain; the memory array is never reset.

| Module | Use | Capacity | Beat latency | Sustained II |
|---|---|---|---|---|
| `async_stream_fifo` | datapath CDC | `DEPTH` RAM + 1 output slot | ~2-3 `m_clk` sync + 1 fetch | 1 both sides |
| `stream_cdc_handshake` | low-rate control/narrow data | 1 slot + 1 in-flight | ~2 `m_clk` sync + capture | 1 per round trip (~4-6 clocks) |

`async_stream_fifo` parameters: `WIDTH>=1`, `DEPTH` power of two `>=2`
(illegal values terminate simulation via `$fatal`). `stream_cdc_handshake`:
`WIDTH>=1`.

`async_stream_fifo` additionally exports `s_level`/`m_level` (AW+2 bits):
writer-side estimated RAM occupancy `wptr_bin - rbin_sync`, and reader-side
visible beats `(wbin_sync - rptr_bin) + m_tvalid`. Both lag by the 2-FF
synchronizer delay and can wrap during reset transients — observability only,
never for flow control.

## Architecture and CDC structure

```
 s_clk domain                 RAM (no reset)              m_clk domain
 s_tvalid/s_tready            +----------+
 wptr_bin/wptr_gray (AW+1) -->| mem[D-1:0]|--> m_tdata/m_tvalid (slot)
      |                       +----------+        ^
      |  rptr_gray --2FF--> rbin_sync              | rptr_bin/rptr_gray
      |<----------------- wptr_gray <-2FF-- wptr_r1/wptr_r2
 s_rst_tog --2FF--> clamp_m (rptr, m_tvalid)   m_rst_tog --2FF--> clamp_s
```

- Pointers are `AW+1`-bit binary counters (wrap bit distinguishes full from
  empty); only their Gray encodings cross domains through 2-FF synchronizers.
  Because Gray changes one bit per increment, a synchronizer sample can only
  resolve to the old or the new value — never an invalid pointer.
- `full` = `wptr_bin - g2b(rptr_w2) == DEPTH`; `empty` =
  `g2b(wptr_r2) == rptr_bin`. The synced pointers lag the true ones, so the
  write side sees occupancy `>=` reality and the read side sees it `<=`
  reality — both comparisons fail in the safe direction.
- Read side uses a registered output slot (`m_tdata`/`m_tvalid`) filled by a
  synchronous RAM read (`fetch`); there is no combinational/FWFT memory read,
  keeping the array BRAM/distributed-RAM inferable on Gowin.
- There is **no combinational ready path across the domains**: `s_tready`
  depends only on write-domain registers, `m_tvalid` only on read-domain
  registers.

## Reset contract (asymmetric recovery — implemented)

Either domain may be reset alone, or both together:

1. Each domain detects its own reset *assertion edge* (`x_rst_d` sampled 1
   followed by `!x_rst_n` at a posedge) and flips a toggle `x_rst_tog`.
   A toggle is a persistent level, so even a 1-cycle reset pulse is always
   detected; closely spaced assertions may merge, which is still safe because
   every detection re-zeroes pointers.
2. The peer samples the toggle through a dedicated 2-FF synchronizer; on any
   detected level change it clamps its own state for `CLAMP_LEN=4` local
   clocks: write side forces `wptr=0`, read side forces `rptr=0` and
   `m_tvalid=0`. Synchronizer flops keep running so pointers re-converge.
3. After convergence both domains hold `(wptr,rptr)=(0,0)` = empty and resume
   handshaking without further coordination.

Scope of discarded in-flight transactions:

- Beats sitting in the output slot are dropped; beats already emitted
  (`m_tvalid && m_tready` edge) stay delivered; beats in flight on the read
  side during the detect window (~2 `m_clk` after peer reset asserts) may be
  delivered in order; beats accepted on the write side before the write clamp
  lands are dropped (written data is overwritten by the rewound pointer).
- Beats accepted *after* the write-side clamp ends while the peer is still
  asserting its local reset are **not** dropped — they flow normally once the
  peer releases. If the integration requires strict "everything queued is
  discarded" semantics, hold `s_tvalid=0` until both sides have been released
  for at least `CLAMP_LEN + 4` periods of the slower clock.
- Recovery requires the peer clock to be toggling while the reset event is
  sampled; resetting one domain with the other clock stopped is not supported
  (documented limitation, inherent to synchronous-reset CDC).
- Successive assertions on one domain should be spaced by at least ~4 clocks
  of the peer domain so each toggle is individually observable; merged events
  still converge to empty.

The same toggle+clamp scheme drives `stream_cdc_handshake` recovery: the peer
clamp forces `req_t`/`ack_t`/`req_seen` to the idle alignment, so no phantom
or duplicated transfer survives.

## Verification method

`tests/test_asyncfifo.py` generates per-domain stimulus on an integer
nanosecond grid (odd half-periods, so a negedge stimulus change can never
coincide with a remote posedge). `models/model.py` contains a bit-exact
register-level model (pointers, Gray code, both synchronizer chains,
reset-toggle detect/clamp state) evaluated with NBA-equivalent staging for
same-timestamp posedges, plus an independent transaction `QueueOracle`.

Per case the testbench drives `wstim.txt`/`rstim.txt`, records
`wtrace.txt`/`rtrace.txt`, and the checker compares every cycle's
`s_tready`/`s_level`/`m_tvalid`/`m_tdata`/`m_level` bit-exactly, runs the
queue oracle across reset quarantines, checks stalled-output stability, full
(`s_level==DEPTH` refusal), empty drain, II=1 push/pop runs, and illegal
parameters. Five mutation fixtures per case (data, order, count, ready,
stall-stability) must all be rejected.

Case matrix: `DEPTH` 2/4/8/16/32, `WIDTH` 1/8/16/32, clock half-period ratios
5:7, 7:5, 5:11, 11:5, 5:5, 9:5, 7:9, 9:7, 13:5 — i.e. fast/slow writer,
fast/slow reader, equal frequency. Each case applies four mid-stream reset
events: write-side only, read-side only, and two coordinated.

## Synthesis

`synth_asyncfifo.py` runs isolated `yosys read_verilog -sv` + `synth_gowin`
(this yosys build has no `-family` flag) and records mapped cell counts. The
RAM is expected to map to distributed SRAM/BSRAM depending on depth; counts
are informational, core-level, not P&R.

## Limitations

- Simulation + structural review only: no metastability MTBF claim, no formal
  proof. Gray-code correctness and clamp convergence are verified by
  bit-exact simulation and code review, not by formal CDC analysis.
- Synchronizers must be placed so the 2-FF chains get real metastability
  resolution time (`async_reg` attributes are hints; P&R constraints must not
  add skew between Gray bits — keep each Gray bus routed together).
- `stream_cdc_handshake`'s `sbuf -> m_tdata` path is a multi-cycle-path data
  crossing: constrain it (e.g. max_delay/datapath-only) and keep sbuf stable —
  guaranteed structurally since sbuf can only change while the channel is
  idle (ack returned).
- Level outputs are estimates, not flow control.
- No board evidence yet.
