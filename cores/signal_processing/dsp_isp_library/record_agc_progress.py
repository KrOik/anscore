"""Record the AGC (DSP-07) simulation/synthesis evidence; no board or
production acceptance claim."""
import json
from pathlib import Path
HERE = Path(__file__).resolve().parent; ROOT = HERE.parents[1]
out = ROOT / 'artifacts/dsp_isp_20260925/agc_tracking'; out.mkdir(exist_ok=False)
p = HERE / 'requirements.json'; (out / 'requirements_before.json').write_bytes(p.read_bytes())
ledger = json.loads(p.read_text(encoding='utf-8')); base = 'cores/signal_processing/dsp_isp_library/dsp/agc/'
m = json.loads((ROOT / base / 'ip_manifest.json').read_text())
r = next(r for r in ledger['requirements'] if r['id'] == 'DSP-07')
r.update(status='仿真通过',
         configurations=['Signed16 streaming AGC; level/gain in octave codes (0.7526 dB); '
                         'target 0..120, gmin/gmax signed9, attack/release/est shifts 0..15, '
                         'log or linear-slew smoothing, mute, bypass, clear; atomic empty-pipe '
                         'config with whole-request reject; reset defaults documented in SPEC'],
         implementation=[base + m['rtl']],
         specification=[base + 'SPEC.md'],
         documentation=[base + 'README.md', base + 'ip_manifest.json'],
         simulation=[base + m['model_evidence'], base + m['rtl_evidence']],
         checker_negative=[base + m['rtl_evidence']],
         synthesis=[base + m['synthesis_evidence']],
         limitations=['Feed-forward topology: attack overshoot is inherent; markers are '
                      'transport delimiters only and are not protocol-validated',
                      'Float-model agreement is behavioural (tail RMS), not bit-exact',
                      'No P&R, board, external-injection or production acceptance'])
model = list((ROOT / base / 'models').glob('*reference*.py')); assert len(model) == 1
r['float_model'] = r['bit_exact_model'] = [str(model[0].relative_to(ROOT)).replace('\\', '/')]
for field in ('implementation', 'specification', 'documentation', 'simulation', 'checker_negative',
              'synthesis', 'float_model', 'bit_exact_model'):
    for path in r[field]:
        assert (ROOT / path).is_file(), path
p.write_text(json.dumps(ledger, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print('DSP-07 isolated model/RTL/synthesis evidence recorded; full acceptance remains open.')
