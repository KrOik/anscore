"""Record INFRA-05 shared fixed-point arithmetic delivery; no board claim."""
import json
from pathlib import Path
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
out = ROOT / 'artifacts/dsp_isp_20260925/fixedpoint_tracking'
out.mkdir(exist_ok=False)
p = HERE / 'requirements.json'
(out / 'requirements_before.json').write_bytes(p.read_bytes())
ledger = json.loads(p.read_text(encoding='utf-8'))
base = 'cores/signal_processing/dsp_isp_library/infra/fixedpoint/'
m = json.loads((ROOT / base / 'ip_manifest.json').read_text())
r = next(r for r in ledger['requirements'] if r['id'] == 'INFRA-05')
r.update(
    status='仿真通过',
    configurations=[
        'sat_round 32->16 sh15 signed; cplx_mac 16/48/32; fp_div_iter+pipe '
        '16/16/15->18; fp_sqrt_iter+pipe 32 fb8; fp_log2_iter 16 fb12 g6; '
        'fp_exp2_iter 16 fb12 g6 out13 fraco6; synthesis alternates '
        'cplx_mac acc40, exp2 out28'],
    implementation=[base + 'rtl/sat_round.sv', base + 'rtl/cplx_mac.sv',
                    base + 'rtl/recip_div.sv', base + 'rtl/sqrt_unit.sv',
                    base + 'rtl/log2exp2.sv'],
    specification=[base + 'SPEC.md'],
    documentation=[base + 'README.md', base + 'ip_manifest.json'],
    simulation=[base + m['model_evidence'], base + m['rtl_evidence']],
    checker_negative=[base + m['rtl_evidence']],
    synthesis=[base + m['synthesis_evidence']],
    float_model=[base + 'models/reference.py'],
    bit_exact_model=[base + 'models/reference.py'],
    limitations=[
        'Iterative log2/exp2 only; no pipelined variants for those functions',
        'Static parameters only, no runtime atomic-config interface on these cores',
        'cplx_mac uses 4 MULT18X18 per instance, the full per-image DSP budget',
        'No P&R, board or production-chain acceptance'])
for field in ('implementation', 'specification', 'documentation',
              'simulation', 'checker_negative', 'synthesis',
              'float_model', 'bit_exact_model'):
    for path in r[field]:
        assert (ROOT / path).is_file(), path
p.write_text(json.dumps(ledger, ensure_ascii=False, indent=2) + '\n',
             encoding='utf-8')
print('INFRA-05 isolated model/RTL/synthesis evidence recorded; '
      'full acceptance remains open.')
