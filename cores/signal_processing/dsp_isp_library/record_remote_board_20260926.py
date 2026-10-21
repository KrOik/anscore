"""Record 2026-09-26 remote board qualification: dock/FX2/UART moved to the
bianbu board (192.168.31.176); all physical runs now execute there via SSH.

- Transport probe (probe.fs sha256 acd8b8bd...) re-qualified on remote:
  openFPGALoader -b tangprimer20k + /dev/ttyUSB1 inject + fx2lafw capture,
  261 fresh decoded bytes PASS -> artifacts/dsp_isp_remote_20260925/uart_probe_01.
- DSP chain production build chain_20260926_102052_596317 (production
  dc_stream.sv + production statistics_stream.sv with folded sqrt_pipeline16,
  dc_latency=2, stats_latency=17, 7963 LUT4 / 3 DSP / Fmax 79.64-116.47 MHz):
  two independent SRAM program+run rounds on remote, 10/10 cases each incl.
  stall0/1/7, all PASS with per-case negative_check ->
  artifacts/dsp_isp_remote_20260926/dsp_chain_prod_01 and _02_reprogram.
"""
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASE = 'cores/signal_processing/dsp_isp_library/'
ART = 'artifacts/'
out = ROOT / 'artifacts/dsp_isp_remote_20260926/tracking'
out.mkdir(parents=True, exist_ok=False)
path = HERE / 'requirements.json'
(out / 'requirements_before.json').write_bytes(path.read_bytes())
ledger = json.loads(path.read_text(encoding='utf-8'))

BOARD1 = ART + 'dsp_isp_remote_20260926/dsp_chain_prod_01/verdict.json'
BOARD2 = ART + 'dsp_isp_remote_20260926/dsp_chain_prod_02_reprogram/verdict.json'
PROBE = ART + 'dsp_isp_remote_20260925/uart_probe_01/verdict.json'

for e in (BOARD1, BOARD2, PROBE):
    v = json.loads((ROOT / e).read_text())
    assert v['status'] == 'PASS', (e, v['status'])

def add(row, field, *paths):
    for item in paths:
        if not (ROOT / item).exists():
            raise FileNotFoundError(item)
        if item not in row.setdefault(field, []):
            row[field].append(item)

BUILD = BASE + 'board/dsp_chain_harness/evidence/chain_20260926_102052_596317/'

for row in ledger['requirements']:
    if row['id'] == 'DSP-04':
        row['status'] = '板测通过'
        add(row, 'simulation', BUILD + 'simulation_summary.json')
        add(row, 'route_timing', BUILD + 'build_summary.json')
        add(row, 'board_injection', BOARD1)
        add(row, 'board_reprogram', BOARD2)
        add(row, 'board_capture', ART + 'dsp_isp_remote_20260926/dsp_chain_prod_01/case_00/capture.sr')
        row['limitations'] = [
            'Production sqrt_pipeline16 source physically qualified through the '
            'dc->statistics chain on remote hardware (bianbu, 2x SRAM reprogram, '
            '10 cases each incl. stall0/1/7, per-case negative_check PASS)',
            'Physical scope bounded: externally loaded <=64-sample blocks, '
            'block replay at target rate, configs as per protocol.cases()',
            'No standalone statistics ip_manifest; full streaming-rate and '
            'arbitrary-block-length acceptance remain open',
        ]
    elif row['id'] == 'DSP-09':
        add(row, 'board_injection', BOARD1)
        add(row, 'board_reprogram', BOARD2)

chains = ledger['integration_chains']
for e in (BOARD1, BOARD2):
    if e not in chains['DSP']['evidence']:
        chains['DSP']['evidence'].append(e)
chains['DSP']['status'] = (
    'physical_pass_production_sqrt16_2x_reprogram_10cases_remote; '
    'production dc_stream + statistics_stream folded pipeline qualified on '
    'bianbu remote harness')

path.write_text(json.dumps(ledger, ensure_ascii=False, indent=2) + '\n',
                encoding='utf-8')
print('Remote board progress recorded.')
