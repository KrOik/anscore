"""Append reviewed physical repair and morphology evidence without retiring failures."""
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASE = 'cores/signal_processing/dsp_isp_library/'
ART = 'artifacts/dsp_isp_20260925/'
out = ROOT / ART / 'pipeline_tracking'
out.mkdir(exist_ok=False)
path = HERE / 'requirements.json'
(out / 'requirements_before.json').write_bytes(path.read_bytes())
ledger = json.loads(path.read_text(encoding='utf-8'))

def add(row, field, *paths):
    for item in paths:
        if not (ROOT / item).exists():
            raise FileNotFoundError(item)
        if item not in row.setdefault(field, []):
            row[field].append(item)

for row in ledger['requirements']:
    if row['id'] == 'DSP-09':
        row['status'] = '板测通过'
        add(row, 'simulation', BASE+'dsp/dc/evidence/mean_long_20260925_030638_578226/summary.json', BASE+'dsp/dc/evidence/rtl_20260925_030736_877822/summary.json', BASE+'dsp/dc/evidence/board_replay_20260925_030743_797974/summary.json')
        add(row, 'board_injection', ART+'dc_candidate_replay_01/verdict.json', ART+'dc_candidate_board_01/verdict.json', ART+'dc_candidate_blocker64_01/verdict.json')
        add(row, 'board_reprogram', ART+'dc_candidate_board_02/verdict.json')
        add(row, 'route_timing', BASE+'board/block_harness/evidence/dc8_inferred_20260925_025755_339428/build_summary.json')
        add(row, 'documentation', BASE+'dsp/dc/ip_manifest.json', BASE+'dsp/dc/README.md')
        row['limitations'] = ['Narrow mean candidate promoted with identical source hash after independent regression; original physical failures remain preserved and their physical cause is not uniquely established', 'Physical scope: pole65024, blocks<=64, mean windows1/8/64; mean64 only startup through first full window; W256 wraps simulation-only', 'Production package integration and broader configuration acceptance remain pending']
    elif row['id'] == 'ISP-01':
        row['status'] = '板测通过'
        add(row, 'implementation', BASE+'isp/candidates/pipeline4/csc_stream.v')
        add(row, 'simulation', BASE+'board/block_harness/evidence/csc8_inferred_20260925_031306_002825/simulation_summary.json', BASE+'board/block_harness/evidence/csc10_inferred_20260925_031627_439716/simulation_summary.json')
        add(row, 'route_timing', BASE+'board/block_harness/evidence/csc8_inferred_20260925_031306_002825/build_summary.json', BASE+'board/block_harness/evidence/csc10_inferred_20260925_031627_439716/build_summary.json')
        add(row, 'board_injection', ART+'csc8_pipeline4_replay_01/verdict.json', ART+'csc8_pipeline4_board_01/verdict.json')
        row['limitations'] = ['Four-stage II1 candidate physical 8bit matrix passes; original one-stage failures retained', '10bit physical and repeat programming results will be appended separately', 'Production default source promotion/integration remains pending; blocks<=64 do not qualify arbitrary sustained frames']
    elif row['id'] == 'ISP-05':
        row['status'] = '仿真通过'
        row['configurations'] = ['K3/5, 8/10bit, erosion/dilation/open/close, binary/grayscale, nonempty asymmetric masks, ZERO/REPLICATE']
        for field, suffixes in {'implementation':['morphology_stream.v','morph_reduce.v'], 'specification':['SPEC.md'], 'bit_exact_model':['model.py'], 'documentation':['README.md'], 'simulation':['evidence/sim_20260925_031412_017581/summary.json','evidence/latency_audit_20260925_031809_694032.json'], 'checker_negative':['evidence/sim_20260925_031412_017581/summary.json'], 'synthesis':['evidence/synth_20260925_031500_464610/summary.json']}.items():
            add(row, field, *(BASE+'isp/morphology/'+suffix for suffix in suffixes))
        row['limitations'] = ['Exact order-statistic algorithm; no floating approximation needed', 'Row II1 only; capture/replay and frame-drain stalls explicitly documented', 'No P&R, physical or production qualification']

path.write_text(json.dumps(ledger, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
print('Reviewed progress recorded; full acceptance remains open.')
