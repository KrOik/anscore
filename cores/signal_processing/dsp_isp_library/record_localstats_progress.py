"""Record ISP-10 localstats isolated evidence; no P&R/board/production claim."""
import json
from pathlib import Path
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
out = ROOT / 'artifacts/dsp_isp_20260925/localstats_tracking'
out.mkdir(exist_ok=False)
p = HERE / 'requirements.json'
(out / 'requirements_before.json').write_bytes(p.read_bytes())
ledger = json.loads(p.read_text(encoding='utf-8'))
base = 'cores/signal_processing/dsp_isp_library/isp/localstats/'
m = json.loads((ROOT / base / 'ip_manifest.json').read_text())
r = next(r for r in ledger['requirements'] if r['id'] == 'ISP-10')
r.update(
    status='仿真通过',
    configurations=[
        'unsigned8/10bit,runtime img 1..MAX_Wx1..MAX_H(MAX_W*MAX_H<=65536),'
        'runtime rectangular window 1..15x1..15,causal trailing top/left-clipped'
        ' window,same-size stream II=1,atomic config signed8 C,'
        'isum/isq+wsum/wsq/area/mean/var sidebands,exact (p+C)*area>wsum binary'],
    implementation=[base + m['rtl'], base + m['rtl_extra']],
    specification=[base + 'SPEC.md'],
    documentation=[base + 'README.md', base + 'ip_manifest.json'],
    simulation=[base + m['model_evidence'], base + m['rtl_evidence']],
    checker_negative=[base + m['rtl_evidence']],
    synthesis=[base + m['synthesis_evidence']],
    limitations=[
        'Causal trailing window only; centered use needs upstream line/frame delay',
        'Integer variance is floor(q/a)-floor(s/a)^2 within (-1,2*mean+1) of exact',
        'No P&R, routed timing or physical/production acceptance'])
models = list((ROOT / base / 'models').glob('*reference*.py'))
assert len(models) == 1
r['float_model'] = r['bit_exact_model'] = [
    str(models[0].relative_to(ROOT)).replace('\\', '/')]
for field in ('implementation', 'specification', 'documentation', 'simulation',
              'checker_negative', 'synthesis', 'float_model', 'bit_exact_model'):
    for path in r[field]:
        assert (ROOT / path).is_file(), path
p.write_text(json.dumps(ledger, ensure_ascii=False, indent=2) + '\n',
             encoding='utf-8')
print('ISP10 isolated model/RTL/synthesis evidence recorded; physical gates open.')
