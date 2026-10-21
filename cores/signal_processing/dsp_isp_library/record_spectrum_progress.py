"""Record DSP-05 spectrum pre/post-processing evidence; no board claim.

Run manually from the repository root after the evidence directories in
dsp/spectrum/ip_manifest.json exist. Updates requirements.json in place and
saves a before-copy under artifacts/dsp_isp_20260925/spectrum_tracking/.
"""
import json
from pathlib import Path
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
out = ROOT / 'artifacts/dsp_isp_20260925/spectrum_tracking'
out.mkdir(exist_ok=False)
p = HERE / 'requirements.json'
(out / 'requirements_before.json').write_bytes(p.read_bytes())
ledger = json.loads(p.read_text(encoding='utf-8'))
base = 'cores/signal_processing/dsp_isp_library/dsp/spectrum/'
m = json.loads((ROOT / base / 'ip_manifest.json').read_text())
r = next(r for r in ledger['requirements'] if r['id'] == 'DSP-05')
rtl = [base + f for c in m['cores'].values() for f in c['rtl']]
r.update(
    status='仿真通过',
    configurations=[
        'window_mult: unity/hann/hamming/blackman/custom-table, N=16..4096 '
        '(2**log2n, log2n 4..12), signed16 Q1.15, signed18 Q3.15 coeffs, '
        '4096-phase cosine ROM, scale_shift -8..15 RNE+saturate, II=1',
        'mag_squared: paired {i,q} signed16 -> unsigned32 I^2+Q^2, shift '
        '0..15 RNE, II=1',
        'block_accum: signed16 -> {sum32,mean16} per block, RNE divide by '
        'N power-of-two, II=1',
        'peak_search: unsigned32 -> {index16,magnitude32} per block, '
        'earliest-index ties, optional threshold flag, II=1'],
    implementation=rtl,
    specification=[base + 'SPEC.md'],
    documentation=[base + 'README.md', base + 'ip_manifest.json'],
    simulation=[base + m['model_evidence'], base + m['rtl_evidence']],
    checker_negative=[base + m['rtl_evidence']],
    synthesis=[base + m['synthesis_evidence']],
    limitations=[
        'No frame-sync sideband; bin/block alignment is the integrator\'s '
        'responsibility',
        'scale_shift approximates coherent-gain correction 1/CG by powers '
        'of two only; residual gain documented in SPEC.md',
        'Block length restricted to powers of two (cosine ROM phase grid)',
        'Isolated-core evidence only: no P&R, routed timing, board or '
        'chain acceptance'])
model = list((ROOT / base / 'models').glob('reference.py'))
assert len(model) == 1
r['float_model'] = r['bit_exact_model'] = [
    str(model[0].relative_to(ROOT)).replace('\\', '/')]
for field in ('implementation', 'specification', 'documentation',
              'simulation', 'checker_negative', 'synthesis', 'float_model',
              'bit_exact_model'):
    for path in r[field]:
        assert (ROOT / path).is_file(), path
p.write_text(json.dumps(ledger, ensure_ascii=False, indent=2) + '\n',
             encoding='utf-8')
print('DSP-05 isolated model/RTL/synthesis evidence recorded; '
      'full acceptance remains open.')
