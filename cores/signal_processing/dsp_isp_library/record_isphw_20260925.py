"""Record the 2026-09-25 ISP chain physical repair: left-edge failure resolved.

Root causes (three distinct GW2A silicon divergences, all confirmed on-board via
the board/window_probe isolation harness):

1. Probe/harness input-store lookahead: `raddr=input_count+1` during replay
   gaps let the read-address drift on silicon. Fixed by presenting
   `input_count` while idle and `+1` only during the take cycle
   (window_probe.v, image_harness.v, block_harness.v).
2. stream_window `if(px==0) history[...]<=0` conditional write competing with
   `history[...+K-2]<=column`: on silicon the pad-column pixel never entered
   history -> left-edge lanes returned 0. The zero was redundant (px<K-1 never
   emits); removed.
3. stream_window_padded `row_mem` issue-gated read mapped to a DPX9B whose
   CEB was a widened shared clock-enable; during output stalls the address
   register re-sampled an already-advanced ridx -> pairwise pixel swaps.
   Fixed by pinning row_mem (and core banks) to fabric registers.

Board evidence: window_probe fix5 build PASS x16 cases
(wp_fix5_8x8k3p1d8_20260925_155951_588728) and full CSC->morphology ISP chain
image8_pad1_20260925_161002_566586 PASS x16 cases on two SRAM program+run
rounds (isp_chain_fixed_01, isp_chain_fixed_02_reprogram).
"""
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
out = ROOT/'artifacts/dsp_isp_20260925/isp_fix_round_20260925_tracking'
out.mkdir(exist_ok=True)
p = HERE/'requirements.json'
(out/'requirements_before.json').write_bytes(p.read_bytes())
ledger = json.loads(p.read_text(encoding='utf-8'))
chains = ledger['integration_chains']

isp_ev = [
    'artifacts/dsp_isp_20260925/isp_chain_fixed_01/verdict.json',
    'artifacts/dsp_isp_20260925/isp_chain_fixed_02_reprogram/verdict.json',
    'artifacts/dsp_isp_20260925/window_probe_fix5_02/verdict.json',
]
for e in isp_ev:
    v = json.loads((ROOT/e).read_text())
    assert v['status'] == 'PASS', (e, v['status'])
    assert (ROOT/e).is_file()
for e in isp_ev:
    if e not in chains['ISP']['evidence']:
        chains['ISP']['evidence'].append(e)
chains['ISP']['status'] = (
    'physical_pass_fixed_window_2x_reprogram_16cases; '
    'production (GW2A CE-widening safe: fabric-reg memories, no-gap lookahead reads)'
)

board_capture = [
    'artifacts/dsp_isp_20260925/isp_chain_fixed_01/case_00/capture.sr',
    'artifacts/dsp_isp_20260925/isp_chain_fixed_01/case_00/decoded.bin',
    'artifacts/dsp_isp_20260925/isp_chain_fixed_02_reprogram/case_00/capture.sr',
    'artifacts/dsp_isp_20260925/isp_chain_fixed_02_reprogram/case_00/decoded.bin',
]
for e in board_capture:
    assert (ROOT/e).is_file(), e

for rid in ('INFRA-02', 'ISP-05'):
    req = next(r for r in ledger['requirements'] if r['id'] == rid)
    req['status'] = '生产集成验收通过'
    req['route_timing'] = sorted(set(req.get('route_timing', []) + [
        'cores/signal_processing/dsp_isp_library/board/image_harness/evidence/image8_pad1_20260925_161002_566586/build_summary.json',
        'cores/signal_processing/dsp_isp_library/board/window_probe/evidence/wp_fix5_8x8k3p1d8_20260925_155951_588728/build_summary.json',
    ]))
    req['board_injection'] = sorted(set(req.get('board_injection', []) + [
        'artifacts/dsp_isp_20260925/isp_chain_fixed_01/verdict.json',
        'artifacts/dsp_isp_20260925/window_probe_fix5_02/verdict.json',
    ]))
    req['board_capture'] = sorted(set(req.get('board_capture', []) + board_capture))
    req['board_reprogram'] = sorted(set(req.get('board_reprogram', []) + [
        'artifacts/dsp_isp_20260925/isp_chain_fixed_02_reprogram/verdict.json',
    ]))
    req['production'] = sorted(set(req.get('production', []) + [
        'cores/signal_processing/dsp_isp_library/board/image_harness/evidence/image8_pad1_20260925_161002_566586/build_summary.json',
    ]))
    req.setdefault('limitations', []).append(
        '2026-09-25 board qualification via CSC->morphology image_harness '
        'sha256=e6dd806b7ce9516f97a593d98e1b2695e56e0e283710723d388619d519855159; '
        '2844 LUT, 0 DSP, 4 DPX9B harness stores, routed Fmax>=110 MHz @27 MHz target; '
        '16/16 cases x2 SRAM rounds PASS incl. exact left-edge regression frame.'
    )

p.write_text(json.dumps(ledger, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print('ISP chain physical PASS recorded; INFRA-02/ISP-05 -> 生产集成验收通过')
