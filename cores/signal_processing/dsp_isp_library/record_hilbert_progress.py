"""Record the Hilbert analytic-signal core; no board acceptance claim."""
import json
from pathlib import Path
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
out = ROOT / 'artifacts/dsp_isp_20260925/hilbert_tracking'
out.mkdir(exist_ok=False)
p = HERE / 'requirements.json'
(out / 'requirements_before.json').write_bytes(p.read_bytes())
ledger = json.loads(p.read_text(encoding='utf-8'))
base = 'cores/signal_processing/dsp_isp_library/dsp/hilbert/'
m = json.loads((ROOT / base / 'ip_manifest.json').read_text())
r = next(r for r in ledger['requirements'] if r['id'] == 'DSP-12')
r.update(
    status='仿真通过',
    configurations=[
        'Antisymmetric Hilbert FIR 4*PAIRS-1 taps (63 default), C=(TAPS-1)/2 '
        'aligned I path, LANES=4 shared multipliers II=5 latency26, paired '
        '80b I/Q+env+phase+freq output, CORDIC envelope, divide+atan-LUT '
        'phase, wrapped-brad frequency, zero-amplitude flag, atomic '
        'pair/coefficient config'],
    implementation=[base + f for f in m['rtl']],
    specification=[base + 'SPEC.md'],
    documentation=[base + 'README.md', base + 'ip_manifest.json'],
    simulation=[base + m['model_evidence'], base + m['rtl_evidence']],
    checker_negative=[base + m['rtl_evidence']],
    synthesis=[base + m['synthesis_evidence']],
    limitations=[
        'Envelope/phase/frequency qualified over 0.05..0.45 cyc/sample for '
        'the default coefficients; out-of-band degradation is recorded not '
        'masked; user coefficients carry no spectral guarantee',
        'II=ceil(PAIRS/LANES)+1 clocks (5 default), not II=1; a 16-lane '
        'parallel variant would exceed the <=4 DSP budget',
        'No P&R or physical/production acceptance'])
model = list((ROOT / base / 'models').glob('*reference*.py'))
assert len(model) == 1
r['float_model'] = r['bit_exact_model'] = [
    str(model[0].relative_to(ROOT)).replace('\\', '/')]
for field in ('implementation', 'specification', 'documentation',
              'simulation', 'checker_negative', 'synthesis',
              'float_model', 'bit_exact_model'):
    for path in r[field]:
        assert (ROOT / path).is_file(), path
p.write_text(json.dumps(ledger, ensure_ascii=False, indent=2) + '\n',
             encoding='utf-8')
print('DSP12 isolated model/RTL/synthesis evidence recorded; '
      'full acceptance remains open.')
