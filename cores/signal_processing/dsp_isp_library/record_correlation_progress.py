"""Record the correlation/matched-filter simulation/synthesis evidence; no
board or production acceptance claim."""
import json
from pathlib import Path
HERE = Path(__file__).resolve().parent; ROOT = HERE.parents[1]
out = ROOT / 'artifacts/dsp_isp_20260925/correlation_tracking'; out.mkdir(exist_ok=False)
p = HERE / 'requirements.json'; (out / 'requirements_before.json').write_bytes(p.read_bytes())
ledger = json.loads(p.read_text(encoding='utf-8')); base = 'cores/signal_processing/dsp_isp_library/dsp/correlation/'
m = json.loads((ROOT / base / 'ip_manifest.json').read_text())
r = next(r for r in ledger['requirements'] if r['id'] == 'DSP-06')
r.update(status='仿真通过',
         configurations=['Runtime ntaps=1..64, signed16 {im,re} samples and taps, real/complex mode, '
                         'correlation/convolution direction, optional conjugation, VALID/FULL tail; '
                         'atomic boundary-only config with full-request reject; '
                         'reset default ntaps=1 real VALID tap0=+32767'],
         implementation=[base + m['rtl']],
         specification=[base + 'SPEC.md'],
         documentation=[base + 'README.md', base + 'ip_manifest.json'],
         simulation=[base + m['model_evidence'], base + m['rtl_evidence']],
         checker_negative=[base + m['rtl_evidence']],
         synthesis=[base + m['synthesis_evidence']],
         limitations=['Serialized two-multiplier MAC; first output rise accept+steps+1 '
                      '(steps=ntaps real, 2*ntaps complex), sample pitch steps+2; no II1 claim',
                      'Argmax uses documented |re|+|im| magnitude proxy with earliest-tie rule',
                      'VALID frames shorter than ntaps emit no data beats and flag p_error',
                      'No P&R, board, external-injection or production acceptance'])
model = list((ROOT / base / 'models').glob('*reference*.py')); assert len(model) == 1
r['float_model'] = r['bit_exact_model'] = [str(model[0].relative_to(ROOT)).replace('\\', '/')]
for field in ('implementation', 'specification', 'documentation', 'simulation', 'checker_negative',
              'synthesis', 'float_model', 'bit_exact_model'):
    for path in r[field]:
        assert (ROOT / path).is_file(), path
p.write_text(json.dumps(ledger, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print('DSP-06 isolated model/RTL/synthesis evidence recorded; full acceptance remains open.')
