"""Record INFRA-07 stream test-source/sink checker evidence into the ledger.

Follows the record_farrow_progress.py pattern: snapshot requirements.json,
fill the INFRA-07 entry with implementation/model/evidence paths, assert every
referenced file exists, then rewrite the ledger.

Run manually from the repository root; it is intentionally NOT executed as
part of the INFRA-07 build itself. No P&R, board, or production acceptance is
recorded.
"""
import json
from pathlib import Path
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
out = ROOT / 'artifacts/dsp_isp_20260925/testsrc_tracking'
out.mkdir(exist_ok=False)
p = HERE / 'requirements.json'
(out / 'requirements_before.json').write_bytes(p.read_bytes())
ledger = json.loads(p.read_text(encoding='utf-8'))
base = 'cores/signal_processing/dsp_isp_library/infra/testsrc/'
m = json.loads((ROOT / base / 'ip_manifest.json').read_text())
r = next(r for r in ledger['requirements'] if r['id'] == 'INFRA-07')
r.update(
    status='仿真通过',
    configurations=[
        'prbs_source seed/nwords finite+unlimited; tone_source multitone<=4 '
        'sweep up/down dwell/step/stop sat; image_pattern_source '
        '1x1/2x2/7x5/1x7/8x1/4x4/9x6 all7patterns nframes; backpressure_sink '
        'modes0/1/2; stream_sink_checker seq/img/crc + mutations; '
        '2 wired chains; synth alternates crc 8/16/32, tone 2/4, image '
        '8/16x4096, sink 8/16, checker 8/16'],
    implementation=[base + m['rtl'][k] for k in m['rtl']],
    specification=[base + 'SPEC.md'],
    documentation=[base + 'README.md', base + 'ip_manifest.json'],
    simulation=[base + m['model_evidence'], base + m['rtl_evidence']],
    checker_negative=[base + m['rtl_evidence']],
    synthesis=[base + m['synthesis_evidence']],
    limitations=[
        'No P&R or physical/production acceptance',
        'tone_source at MAX_TONES=4 sits exactly at the 4-DSP per-image '
        'limit; combined usage must fit the enclosing image budget',
        'CRC is a transport aid only, not a numerical acceptance mechanism',
        'tone LUT quantization bound is validated, not analytical'],
    progress_note='')
model = list((ROOT / base / 'models').glob('*reference*.py'))
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
print('INFRA-07 model/RTL/synthesis evidence recorded; '
      'board/production acceptance remains open.')
