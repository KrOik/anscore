# Four-stage exact floor-square-root candidate

This is an isolated candidate; production statistics RTL and golden models are
unchanged. The original DCv3/statistics board chain returned incorrect RMS fields
at full rate while all other fields and UART copies agreed. Reprogramming with
the same input failed again but the erroneous RMS values changed. Stall=7 passed
that input. These observations motivate pipeline separation; they do not prove
a unique physical root cause. Original artifacts remain untouched.

`generate.py` records the original statistics source SHA, renames its leaf,
removes the old `sqrt_floor` function and substitutes constant zero in only the
old RMS field. It appends `wrapper.vh`; it does not edit production RTL. The
generated single-file `statistics_stream.sv` is the build source.

The registered leaf computes the unchanged position/power/meanabs/peak/amplitude
and flags. Four additional elastic register stages each perform four binary
restoring square-root iterations on the leaf's rounded 32-bit mean power. All
other fields and flags travel through the same stages. Output RMS is exact
`floor(sqrt(mean_power))`, never rounded or replaced by magnitude. Total
statistics latency=5, II=1; with production DCv3 total chain latency=7.
Stages advance independently when empty or their successor accepts. Output holds
under stall. Config presentation blocks new input; config acceptance requires
the original leaf and all four added stages empty. Illegal config preserves
state. Reset discards all valid stages and existing leaf histories.

Executed independent RTL tests:

- Original failed input, production statistics latency1 direct replay:
  `evidence/sim_20260925_040522_679144/summary.json` PASS. Original chain full-UART
  replay: `board/dsp_chain_harness/evidence/chain_20260925_040234_962726/` PASS.
  Thus ideal RTL simulation did not reproduce the physical error.
- Candidate independent cycle oracle: `evidence/sim_20260925_040537_388398/`
  PASS, 40000 cycles, 26478 accepted samples, 16699 transferred outputs,
  84 legal configs, two illegal configs, 28 reset edges including nine occupied
  resets, 1383 waiting-config cycles, long sink stalls and both square variants.
  Separate RMS/data/valid/ready/flags/config mutations were all rejected.
- Floor arithmetic boundary test: `evidence/sqrt_20260925_040845_864098/`
  PASS, 206606 distinct inputs for q²−1/q²/q²+1 for every unsigned16 q within the unsigned32 domain,
  plus 10000 seeded random radicands. Expected roots use Python `math.isqrt`.

Commands from repository root:

```
python cores/signal_processing/dsp_isp_library/dsp/statistics/candidates/sqrt_pipeline4/test_candidate.py
python cores/signal_processing/dsp_isp_library/dsp/statistics/candidates/sqrt_pipeline4/test_sqrt_boundaries.py
python cores/signal_processing/dsp_isp_library/board/dsp_chain_harness/run.py --statistics-source cores/signal_processing/dsp_isp_library/dsp/statistics/candidates/sqrt_pipeline4/statistics_stream.sv --stats-latency 5 --build
```

Both source and full UART runners accept `--vector-json` for the original
host-input JSON; expected results are recomputed from independent DC/statistics
models, never copied from captured outputs. Physical qualification is owned by
the main agent. No production promotion is authorized by this candidate README.

Strict full-chain UART/synthesis/route/pack PASS:
`board/dsp_chain_harness/evidence/chain_20260925_040649_856760/`.
The UART matrix checks 577 complete outputs, six invalid requests, 110 mutated
reports and transport faults. Full-rate 64-sample blocks require 71 RUN clocks.
Candidate original-host full-UART replay independently PASS:
`board/dsp_chain_harness/evidence/chain_20260925_040901_161923/`.

Actual noalu chain resources: 7685 LUT1–4, 3 MULT18X18, 6 BRAM. Final routed
tool Fmax=149.70 MHz with required clock=27 MHz. `check -assert` reports zero
problems and full-log audit passes; PNR has no warnings. `chain.fs` SHA256:
`fd4412cc3b4dc397d09798befdd93ed64ff7cffc59c3bdcde952ac7b81619ad6`.
These tool estimates are not physical acceptance.

`audit_mapping.py <build>` checks the actual mapped netlist and produces
`sqrt_mapping_audit.json`: original leaf RMS bits all have GND drivers; old
sqrt function and named logic are absent; the four root stages contain 4/8/12/16
DFFE-driven bits respectively, and final RMS is the exact fourth-stage root
alias. This demonstrates register insertion and old arithmetic removal in the
real synthesized design, beyond source inspection alone.

Parent's separate full DC2+statistics5 chain control/numerical regression also
PASS: `chains/dc_statistics/evidence/sim_20260925_041008_503014/summary.json`
(34000 cycles plus six checker mutations). Candidate source SHA256:
`9cb659dac0e75ad56a325b50bcaea5562686d6fe59a11e98835fdf66f93b2092`.
