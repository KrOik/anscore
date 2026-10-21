"""Record the DSP-14 STFT/Welch core; simulation-level status only."""
import json
from pathlib import Path
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
out = ROOT / 'artifacts/dsp_isp_20260925/stft_tracking'
out.mkdir(exist_ok=False)
p = HERE / 'requirements.json'
(out / 'requirements_before.json').write_bytes(p.read_bytes())
ledger = json.loads(p.read_text(encoding='utf-8'))
base = 'cores/signal_processing/dsp_isp_library/dsp/stft/'
m = json.loads((ROOT / base / 'ip_manifest.json').read_text())
r = next(r for r in ledger['requirements'] if r['id'] == 'DSP-14')
r.update(
    status='仿真通过',
    configurations=['N=64 fixed via fft64,hop8/16/32/64 overlap ring,'
                    'unity/hann/hamming/blackman/custom window wshift-8..15,'
                    'one/two-sided records,block A=1..256 or exp alpha1..8 '
                    'average,pshift0..15,sustained rate bound H/T_frame'],
    implementation=[base + m['rtl']],
    specification=[base + 'SPEC.md'],
    documentation=[base + 'README.md', base + 'ip_manifest.json'],
    simulation=[base + m['model_evidence'], base + m['rtl_evidence']],
    checker_negative=[base + m['rtl_evidence']],
    synthesis=[base + m['synthesis_evidence']],
    limitations=['Serialized fft64 engine: frame cost ~900 clk, sustained '
                 'input bounded by H/T_frame; no II=1',
                 '5 MULT18X18 exceeds 4-DSP board-image budget',
                 'No P&R, timing, board or production acceptance',
                 'fft64 stage-wrap scaling preserved; PSD normalization '
                 'constants documented, fs scaling off-chip'])
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
print('DSP14 isolated model/RTL/synthesis evidence recorded; '
      'full acceptance remains open.')
