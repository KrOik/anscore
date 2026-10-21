"""Record ISP-08 basic_isp isolated evidence; no P&R/board/production claim.

Scope note: this records the composed BLC -> WB-gain -> DPC -> gamma-LUT
pipeline plus the AWB *statistics* source and the host-side gray-world
estimator model only.  In-hardware auto-WB estimation and any closed-loop
update are explicitly NOT claimed (goal.md ISP-08 wording: estimation needs
a defined algorithm/statistics source - here: post-BLC channel sums +
documented gray-world model; gain application stays on the external cfg
path).
"""
import json
from pathlib import Path
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
out = ROOT / 'artifacts/dsp_isp_20260925/basicisp_tracking'
out.mkdir(exist_ok=False)
p = HERE / 'requirements.json'
(out / 'requirements_before.json').write_bytes(p.read_bytes())
ledger = json.loads(p.read_text(encoding='utf-8'))
base = 'cores/signal_processing/dsp_isp_library/isp/basic_isp/'
m = json.loads((ROOT / base / 'ip_manifest.json').read_text())
r = next(r for r in ledger['requirements'] if r['id'] == 'ISP-08')
r.update(
    status='仿真通过',
    configurations=[
        'unsigned8/10bit,CH=1 gray or CH=3 packed {R,G,B},static WIDTHxHEIGHT'
        ' (window foundation is fixed-geometry;cfg img_w/img_h must equal it),'
        'pipeline blc->wb_gain->dpc->gamma: per-channel BLC subtract+clamp,'
        ' UQ4.8 WB gain RNE+saturate, DPC |center-med8of8nbr|>thr->med8'
        ' (3x3 REPLICATE via unmodified infra stream_window_padded,per-channel'
        ' independent,<=3-neighbour clusters exact,>=4 documented bound),'
        ' gamma 33-node PWL LUT sel 0/1/2 (generated table,toe error bounded)'
        ';atomic cfg between idle frames;AWB post-BLC channel sums +'
        ' awb_new/awb_frame; host-side gray-world estimate only'],
    implementation=[base + m['rtl']] + [base + s for s in m['rtl_stages']],
    specification=[base + 'SPEC.md'],
    documentation=[base + 'README.md', base + 'ip_manifest.json'],
    simulation=[base + m['model_evidence'], base + m['rtl_evidence']],
    checker_negative=[base + m['rtl_evidence']],
    synthesis=[base + m['synthesis_evidence']],
    limitations=[
        'Static geometry only (stream_window_padded is fixed-parameter); '
        'cfg img fields are a legality check, not resizers',
        'Bayer-domain operation out of scope (DPC needs 5x5 same-phase); '
        'CH=1 is gray/single-plane',
        'DPC input accept is bursty (capture/replay); output is one beat '
        'per pixel, end-to-end input II is not 1',
        'External WB gain application vs auto estimation are separate: '
        'estimation is host-side gray-world on committed frame sums, no '
        'in-hardware divide or closed loop claimed',
        '>=4 same-direction defective neighbours may be under-corrected '
        '(defined cluster bound)',
        'Gamma encode PWL toe error up to 15/60 LSB at 8/10-bit (measured)',
        'No P&R, routed timing or physical/production acceptance'])
models = sorted((ROOT / base / 'models').glob('*reference*.py'))
assert len(models) == 1
r['float_model'] = r['bit_exact_model'] = [
    str(models[0].relative_to(ROOT)).replace('\\', '/')]
for field in ('implementation', 'specification', 'documentation', 'simulation',
              'checker_negative', 'synthesis', 'float_model', 'bit_exact_model'):
    for path in r[field]:
        assert (ROOT / path).is_file(), path
p.write_text(json.dumps(ledger, ensure_ascii=False, indent=2) + '\n',
             encoding='utf-8')
print('ISP-08 isolated model/RTL/synthesis evidence recorded; physical gates open.')
