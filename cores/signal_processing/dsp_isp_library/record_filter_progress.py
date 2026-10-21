"""Add reviewed median/gradient evidence and preserve v2 physical failures."""
import json
from pathlib import Path
HERE=Path(__file__).resolve().parent;ROOT=HERE.parents[1]
B='cores/signal_processing/dsp_isp_library/';A='artifacts/dsp_isp_20260925/'
out=ROOT/A/'filter_tracking';out.mkdir(exist_ok=False)
p=HERE/'requirements.json';(out/'requirements_before.json').write_bytes(p.read_bytes())
ledger=json.loads(p.read_text(encoding='utf-8'))
for row in ledger['requirements']:
    if row['id']=='DSP-09':
        row['failed_board_evidence'] += [A+'dc_roundv2_boundaries_01/verdict.json',A+'dc_roundv2_baseline_replay_01/verdict.json']
        row['limitations'].append('v2 fixed-width rounding repairs blocker boundary but baseline pole65535 still fails one fullrate sample; stall7 diagnostic passes; independent latency2 v3 candidate under test')
    if row['id'] not in ('ISP-03','ISP-04'):continue
    median=row['id']=='ISP-03';base=B+'isp/'+('median/' if median else 'gradient/')
    sim='evidence/'+('sim_20260925_033407_661717/' if median else 'sim_20260925_033606_099677/')+'summary.json'
    synth='evidence/'+('synth_20260925_033703_241459/' if median else 'synth_20260925_033507_435178/')+'summary.json'
    fields=dict(implementation=['median_stream.v','median_network.v'] if median else ['gradient_stream.v'],specification=['README.md'],documentation=['README.md'],float_model=['model.py'],bit_exact_model=['model.py'],simulation=[sim],checker_negative=[sim],synthesis=[synth])
    if median:fields['simulation'].append('evidence/timing_20260925_033759_288873/summary.json')
    for field,paths in fields.items():
        row[field]=[base+name for name in paths]
        for name in row[field]:assert (ROOT/name).is_file(),name
    row['status']='仿真通过'
    row['configurations']=['K3/5, 8/10bit, ZERO/REPLICATE, unsigned exact median; bitonic80/240 comparators,10/15 levels'] if median else ['Sobel/Scharr 3x3,8/10bit,ZERO/REPLICATE,signedGx/Gy,Euclidean floor sqrt or L1,8 directions,inclusive threshold']
    row['limitations']=['Sorter row II1, padded window capture/replay limits frame rate','No P&R, physical or production acceptance'] if median else ['Arithmetic II2 L1 or15/17Euclidean; no continuous II1 claim','Direction angular error bounded22.507389 degrees; L1 not exact Euclidean','No P&R, physical or production acceptance']
p.write_text(json.dumps(ledger,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print('Median/gradient and v2 physical failures recorded; no acceptance changes.')
