# DC removal to signal statistics

This representative DSP chain connects the DC residual to the statistics core.
The baseline half is deliberately not fed into statistics. Both algorithms retain
their independently defined numerical contracts and use their existing models.
No old RTL, golden, or UART contract is changed.

Input is signed16 Q1.15 Stream. Output is the statistics128-bit record and2-bit
flags: position, mean power, mean absolute value, floor RMS, earliest-tie peak,
latest magnitude; flags are clipping and threshold. See the reused statistics
SPEC for field widths and units. The DC core supports blocker, mean removal and
baseline tracking, with its original guarded state, RNE and output saturation.

The unified configuration contains all DC and statistics fields. As soon as a
configuration is presented, new input is paused while all output slots drain.
One atomic legal commit clears both algorithm histories, including any partial
statistics block. An illegal field rejects the entire update, preserving both
histories; `cfg_done` acknowledges either outcome and `cfg_error` marks rejection.
The source must hold configuration fields until `cfg_ready`. Waiting for config
does not block already accepted data from draining. Output backpressure can defer
configuration indefinitely. Reset is low-active synchronous and discards in-flight
data and algorithm history, without clearing the DC coefficient/history RAM.

With the two-stage DC v3 and the current pipelined-root statistics core
(stats latency17), sliding mode has no-stall latency19 and II1; nineteen
result slots hold two DC results and seventeen statistics results. Ready
propagates through individually elastic stages. Block mode emits
one result per N accepted inputs; the first result becomes available N+18
cycles after the first input edge. Wall-clock latency extends under source
gaps or sink backpressure. Partial blocks need more input or an explicit
config/reset to clear.
`LOGIC_SQUARE=1` preserves the functionality while leaving the DSP budget for DC.

Reproduce from the repository root:

```sh
python cores/signal_processing/dsp_isp_library/chains/dc_statistics/test_chain.py
python cores/signal_processing/dsp_isp_library/chains/dc_statistics/synth_chain.py
```

The 34000-cycle simulation checks composed independent models on every cycle,
with21143 accepted inputs,19426 outputs,22 configuration acknowledgments,
8 illegal updates,560 cycles of waiting configuration,3 occupied-pipeline resets,
and six deliberately corrupted fixtures. Window256 is allowed to fill and wrap.
Evidence: `evidence/sim_20260925_032740_517370/summary.json`.

That initial evidence uses the historical one-stage DC (chain latency2/capacity2).
The v3 candidate composition was separately verified in
`evidence/sim_20260925_034705_299351/summary.json`:34000 cycles,21299 inputs,
19577 outputs,22 configurations including8 invalid updates,581 config-wait cycles,
3 occupied resets and six rejected mutations. The model explicitly distinguishes
per-stage elasticity from global pipeline stall. An earlier scoreboard assumed
global stall and incorrectly rejected a legal ready assertion; that failed run is
retained. Default tests derive DC latency from its active manifest. Explicit
alternate sources use `--dc-source <path> --dc-latency 1|2`.

After the production statistics fold to the 16-stage root pipeline
(`dsp/statistics/FIXNOTE.md`), the default `--stats-latency` is17 and the
folded composition re-verified at `evidence/sim_20260925_163928_345544/`:
34000 cycles,22037 inputs,19880 outputs,22 configurations including8 invalid,
992 config-wait cycles,3 occupied resets and six rejected mutations.

Isolated noalu synthesis PASS:7619 LUT1–4,1583 FF,3 MULT18X18,1 DPX9B,
773 wider mux cells listed separately. Evidence:
`evidence/synth_20260925_033036_401630/summary.json`. These exclude wrapper
resources and do not establish routed27MHz timing.

This is an isolated integration, not the required final physical DSP chain
acceptance. Historical one-stage DC pole65535 failures remain preserved in
`artifacts/dsp_isp_20260925/dc_candidate_boundaries_01/`. DC v3 passes those
boundaries and reprogrammed standalone matrices; that does not qualify this chain.
The separate `board/dsp_chain_harness/` now exports all128 bits plus flags, passes
UART simulation/structural audit and routes within budget. Its first physical
session `artifacts/dsp_isp_20260925/dsp_chain_v3_board_01/` FAILS RMS values;
all other fields agree. Raw LA and serial are identical. RMS pipeline repair,
repeat hardware checks and production chain qualification remain pending.
