"""Record ISP-12 ispstats isolated evidence; no P&R/board/production claim.

Scope note: this records the AE/AWB/AF *statistics* core plus the offline
host-side analysis model only.  Closed-loop AE control is explicitly NOT
claimed (goal.md ISP-12: real camera closed-loop needs camera-interface
evidence, which this delivery does not provide).
"""
import json
from pathlib import Path
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
out = ROOT / 'artifacts/dsp_isp_20260925/ispstats_tracking'
out.mkdir(exist_ok=False)
p = HERE / 'requirements.json'
(out / 'requirements_before.json').write_bytes(p.read_bytes())
ledger = json.loads(p.read_text(encoding='utf-8'))
base = 'cores/signal_processing/dsp_isp_library/isp/ispstats/'
m = json.loads((ROOT / base / 'ip_manifest.json').read_text())
r = next(r for r in ledger['requirements'] if r['id'] == 'ISP-12')
r.update(
    status='仿真通过',
    configurations=[
        'unsigned8/10bit,CH=1 gray or CH=3 packed {R,G,B},runtime img '
        '1..MAX_Wx1..MAX_H(dim<=1024,MAX_W*MAX_H<=65536),runtime zone grid '
        'zones_x x zones_y 1..8 each with zones<=dim (no empty zones),'
        'per-zone {count,sum0,sum1,sum2,oe,focus}: channel sums,any-channel'
        ' thresh overexposure count,causal first-difference gradient energy'
        ' on luma;input II=1;independent ping-pong result RAM readout with'
        ' res_new/res_done/res_frame/res_count and 1-cycle sync-read;'
        'atomic config between frames,illegal fields rejected'],
    implementation=[base + m['rtl']],
    specification=[base + 'SPEC.md'],
    documentation=[base + 'README.md', base + 'ip_manifest.json'],
    simulation=[base + m['model_evidence'], base + m['rtl_evidence']],
    checker_negative=[base + m['rtl_evidence']],
    synthesis=[base + m['synthesis_evidence']],
    limitations=[
        'Statistics + offline analysis model only; closed-loop AE/AWB/AF not '
        'claimed (camera-interface evidence absent)',
        'Focus operator is causal first-difference gradient, not 3x3 Sobel',
        'Empty zones (grid finer than image dims) rejected as illegal config',
        'Record set readable for one following frame; not flow-controlled',
        'No P&R, routed timing or physical/production acceptance'])
models = sorted((ROOT / base / 'models').glob('*reference*.py'))
assert len(models) == 1
r['float_model'] = r['bit_exact_model'] = [
    str(models[0].relative_to(ROOT)).replace('\\', '/')]
r['documentation'].append(base + 'models/ae_analysis.py')
for field in ('implementation', 'specification', 'documentation', 'simulation',
              'checker_negative', 'synthesis', 'float_model', 'bit_exact_model'):
    for path in r[field]:
        assert (ROOT / path).is_file(), path
p.write_text(json.dumps(ledger, ensure_ascii=False, indent=2) + '\n',
             encoding='utf-8')
print('ISP12 isolated model/RTL/synthesis evidence recorded; physical gates open.')
