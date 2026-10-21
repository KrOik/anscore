"""Record ISP-07 bayer isolated evidence; no P&R/board/production claim."""
import json
from pathlib import Path
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
out = ROOT / 'artifacts/dsp_isp_20260925/bayer_tracking'
out.mkdir(exist_ok=False)
p = HERE / 'requirements.json'
(out / 'requirements_before.json').write_bytes(p.read_bytes())
ledger = json.loads(p.read_text(encoding='utf-8'))
base = 'cores/signal_processing/dsp_isp_library/isp/bayer/'
m = json.loads((ROOT / base / 'ip_manifest.json').read_text())
r = next(r for r in ledger['requirements'] if r['id'] == 'ISP-07')
r.update(
    status='仿真通过',
    configurations=[
        'unsigned8/10bit,static WIDTHxHEIGHT>=1x1 (verified 1x1..32x24),'
        'RGGB/BGGR/GRBG/GBRG via cfg_cfa + cfg_ox/cfg_oy ROI-origin parity'
        ' (all 16 combos),atomic config between frames,REPLICATE 3x3 window,'
        'truncating bilinear averages,{R,G,B} per-pixel output,'
        'SOF/EOL passthrough with marker alignment check'],
    implementation=[base + m['rtl'],
                    'cores/signal_processing/dsp_isp_library/' + m['rtl_extra'],
                    'cores/signal_processing/dsp_isp_library/' + m['rtl_extra2']],
    specification=[base + 'SPEC.md'],
    documentation=[base + 'README.md', base + 'ip_manifest.json'],
    simulation=[base + m['model_evidence'], base + m['rtl_evidence']],
    checker_negative=[base + m['rtl_evidence']],
    synthesis=[base + m['synthesis_evidence']],
    limitations=[
        'Static WIDTH/HEIGHT per elaboration; runtime resize needs a '
        'different window contract',
        'Boundary handling is edge REPLICATE only; no border-aware kernel',
        'No P&R, routed timing or physical/production acceptance'])
models = list((ROOT / base / 'models').glob('*reference*.py'))
assert len(models) == 1
r['float_model'] = r['bit_exact_model'] = [
    str(models[0].relative_to(ROOT)).replace('\\', '/')]
for field in ('implementation', 'specification', 'documentation',
              'simulation', 'checker_negative', 'synthesis', 'float_model',
              'bit_exact_model'):
    for path in r[field]:
        assert (ROOT / path).is_file(), path
p.write_text(json.dumps(ledger, ensure_ascii=False, indent=2) + '\n',
             encoding='utf-8')
print('ISP07 isolated model/RTL/synthesis evidence recorded; physical gates open.')
