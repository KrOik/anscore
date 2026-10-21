"""Record the Goertzel bank simulation/synthesis evidence; no board or
production acceptance claim."""
import json
from pathlib import Path
HERE = Path(__file__).resolve().parent; ROOT = HERE.parents[1]
out = ROOT / 'artifacts/dsp_isp_20260925/goertzel_tracking'; out.mkdir(exist_ok=False)
p = HERE / 'requirements.json'; (out / 'requirements_before.json').write_bytes(p.read_bytes())
ledger = json.loads(p.read_text(encoding='utf-8')); base = 'cores/signal_processing/dsp_isp_library/dsp/goertzel/'
m = json.loads((ROOT / base / 'ip_manifest.json').read_text())
r = next(r for r in ledger['requirements'] if r['id'] == 'DSP-13')
r.update(status='仿真通过',
         configurations=['Runtime N=1..256, 1..4 signed19 Q3.16 bins, per-index unsigned16 Q1.15 window, '
                         'unsigned80 thresholds; atomic boundary-only config with full-request reject; '
                         'reset default N=1 DC bin unity window zero threshold'],
         implementation=[base + m['rtl']],
         specification=[base + 'SPEC.md'],
         documentation=[base + 'README.md', base + 'ip_manifest.json'],
         simulation=[base + m['model_evidence'], base + m['rtl_evidence']],
         checker_negative=[base + m['rtl_evidence']],
         synthesis=[base + m['synthesis_evidence']],
         limitations=['Independent direct-DFT agreement verified within documented quantization bound; '
                      'block-end latency 251+50*bins to first output, 201 per further bin, no II1 claim',
                      'Signed40 state saturation and unsigned80 power clip are unreachable with legal '
                      'parameters; m_error paths are structural only',
                      'No P&R, board, external-injection or production acceptance'])
model = list((ROOT / base / 'models').glob('*reference*.py')); assert len(model) == 1
r['float_model'] = r['bit_exact_model'] = [str(model[0].relative_to(ROOT)).replace('\\', '/')]
for field in ('implementation', 'specification', 'documentation', 'simulation', 'checker_negative',
              'synthesis', 'float_model', 'bit_exact_model'):
    for path in r[field]:
        assert (ROOT / path).is_file(), path
p.write_text(json.dumps(ledger, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print('DSP13 isolated model/RTL/synthesis evidence recorded; full acceptance remains open.')
