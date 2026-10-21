"""Record the 2026-09-25 main-agent board round: DSP chain physical PASS
(sqrt_pipeline16 candidate) and ISP chain confirmed left-edge physical failure.

Root cause for the DSP RMS failure (documented in
board/dsp_chain_harness/STATUS.md follow-up): the 4-iteration combinational
sqrt stages could not settle within one 27 MHz cycle on silicon, and the
stage-0 radicand evaluation on transitioning leaf_data captured a
mid-transition blend. One restoring iteration per register stage (16 stages)
resolves it on hardware: two independent SRAM program + 11-case runs PASS.
"""
import json
from pathlib import Path
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
out = ROOT/'artifacts/dsp_isp_20260925/board_round_20260925_tracking'
out.mkdir(exist_ok=True)
p = HERE/'requirements.json'
(out/'requirements_before.json').write_bytes(p.read_bytes())
ledger = json.loads(p.read_text(encoding='utf-8'))
chains = ledger['integration_chains']

dsp_ev = [
 'artifacts/dsp_isp_20260925/dsp_chain_sqrt4_board_01/verdict.json',
 'artifacts/dsp_isp_20260925/dsp_chain_sqrt4_stall_01/verdict.json',
 'artifacts/dsp_isp_20260925/dsp_chain_sqrt4_stall7_01/verdict.json',
 'artifacts/dsp_isp_20260925/dsp_chain_sqrt16_board_01/verdict.json',
 'artifacts/dsp_isp_20260925/dsp_chain_sqrt16_board_02/verdict.json',
]
for e in dsp_ev:
    v = json.loads((ROOT/e).read_text())
    assert v['status'] in ('PASS', 'FAIL') and (ROOT/e).is_file()
assert json.loads((ROOT/'artifacts/dsp_isp_20260925/dsp_chain_sqrt16_board_01/verdict.json').read_text())['status'] == 'PASS'
assert json.loads((ROOT/'artifacts/dsp_isp_20260925/dsp_chain_sqrt16_board_02/verdict.json').read_text())['status'] == 'PASS'
for e in dsp_ev:
    if e not in chains['DSP']['evidence']:
        chains['DSP']['evidence'].append(e)
chains['DSP']['status'] = (
    'physical_pass_sqrt16_candidate_2x_reprogram_11cases; '
    'production statistics still unpatched legacy (DSP-04 re-qualification pending)'
)

isp_ev = 'artifacts/dsp_isp_20260925/isp_chain8_board_02/verdict.json'
assert json.loads((ROOT/isp_ev).read_text())['status'] == 'FAIL'
if isp_ev not in chains['ISP']['evidence']:
    chains['ISP']['evidence'].append(isp_ev)
chains['ISP']['status'] = (
    'physical_left_edge_failure_confirmed_on_repaired_build; '
    'isolated window-memory board probe under construction (board/window_probe)'
)

p.write_text(json.dumps(ledger, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print('board round recorded: DSP chain physical PASS via sqrt16 candidate; ISP left-edge failure confirmed')
