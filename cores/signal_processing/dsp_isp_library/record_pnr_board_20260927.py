"""Record 2026-09-27 route/timing audit + generic-harness board qualification.

Evidence classes:
  A) tools/pnr_audit.py wrapper P&R: per-case summary.json under
     <core>/evidence/pnr_*/<case>/summary.json  (lut/ff/dsp/bram/fmax/gates)
  B) dsp_stream_harness dstream.fs builds + remote board verdicts
     artifacts/dstream_board_20260927/<core>_01/verdict.json + case_*/capture.sr
  C) isp_stream_harness image.fs builds + remote board verdicts (same layout)

Updates requirements.json: route_timing evidence paths, board_injection /
board_capture paths, per-requirement stage_status {rtl_sim, synthesis,
route_timing, board_test, fx2_capture} = PASS/FAIL/BLOCKED with reasons.
"""
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
ART = Path('artifacts/dstream_board_20260927')

# requirement id -> list of (case dir path relative to ROOT) pnr summaries
def pnr_summaries():
    out = {}
    for sj in sorted(ROOT.glob('cores/signal_processing/dsp_isp_library/**/evidence/pnr_*/**/summary.json')):
        d = json.loads(sj.read_text())
        key = (d['req'], d['case'])
        cur = out.get(key)
        if cur is None or sj.stat().st_mtime > cur[1]:
            out[key] = (sj.relative_to(ROOT).as_posix(), sj.stat().st_mtime, d)
    return out

# board run dir -> (requirement id, coverage note); *_02_reprogram = second
# independent SRAM program + retest round (board_reprogram evidence)
BOARD = {
    'farrow_01':      ('DSP-11', 'farrow_cubic 4 cases stall0/1/7 neg-check'),
    'agc_01':         ('DSP-07', 'agc 4 cases stall0/1/7 neg-check'),
    'biquad_01':      ('DSP-02', 'biquad 4 canned SOS configs stall0/1/7 neg-check'),
    'lms_01':         ('DSP-15', 'lms serial 4 configs stall0/1/7 neg-check'),
    'mag_squared_01': ('DSP-05', 'mag_squared only (of 4 DSP-05 modules) 4 cases'),
    'conv_01':        ('ISP-02', 'convolution k3 4 kernels 16 frames'),
    'gradient_01':    ('ISP-04', 'gradient sobel/scharr 16 frames'),
    'median_01':      ('ISP-03', 'median k3 16 frames'),
    'morphology_01':  ('ISP-05', 'morphology erode/dilate/open/close 16 frames'),
    'farrow_02_reprogram':      ('DSP-11', 'reprogram round 2'),
    'agc_02_reprogram':         ('DSP-07', 'reprogram round 2'),
    'biquad_02_reprogram':      ('DSP-02', 'reprogram round 2'),
    'lms_02_reprogram':         ('DSP-15', 'reprogram round 2'),
    'mag_squared_02_reprogram': ('DSP-05', 'reprogram round 2'),
    'conv_02_reprogram':        ('ISP-02', 'reprogram round 2'),
    'gradient_02_reprogram':    ('ISP-04', 'reprogram round 2'),
    'median_02_reprogram':      ('ISP-03', 'reprogram round 2'),
    'morphology_02_reprogram':  ('ISP-05', 'reprogram round 2'),
}

# interface-shape reasons a core has no packet-harness adapter yet
BLOCK_REASON = {
 'DSP-01': 'rate-change M:1/1:L breaks the 1:1 BLK1 packet contract - need multi-count harness adapter',
 'DSP-03': 'ddc/duc rate change (decim/interp) - needs multi-count harness adapter',
 'DSP-06': 'correlation produces per-lag block reports not 1:1 stream - needs block-report adapter',
 'DSP-08': 'carrier/timing loops emit status taps + wide status - adapterable but not yet built',
 'DSP-10': 'halfband/cic rate change - needs multi-count harness adapter',
 'DSP-12': 'hilbert emits 80-bit lane-packed analytic words > 32b packet word',
 'DSP-13': 'goertzel emits per-bin 80-bit power frames - needs wide-word adapter',
 'DSP-14': 'stft emits 128-bin PSD frames per 256-sample block - needs frame adapter',
 'DSP-16': 'pfb emits M-channel interleaved output - needs multi-channel adapter',
 'ISP-06': 'scale_poly6 remote attempts FAILED: framing/length 0 vs 8218 (scale_board_02..04) - harness protocol mismatch under investigation',
 'ISP-07': 'bayer demosaic needs 2D frame + sensor pattern cfg - adapterable via isp_stream_harness',
 'ISP-08': 'basic_isp_top is a multi-stage pipeline (blc/dpc/wb/gamma/awb) - needs multi-cfg harness',
 'ISP-09': 'cca emits label maps + feature list - needs report adapter',
 'ISP-10': 'integral_stats emits box responses - adapterable; adaptive_threshold has dual stream',
 'ISP-11': 'histeq needs frame-accumulate-then-replay (CDF build) - needs two-pass adapter',
 'ISP-12': 'ispstats emits per-channel stats tuples wider than 30b - needs wide-word adapter',
 'ISP-13': 'lsc needs gain LUT table load - needs table-load adapter',
 'ISP-14': 'ccm needs 3x3 matrix cfg + 24-bit RGB - adapterable',
 'ISP-15': 'chroma 422/420 change spatial format - adapterable',
 'ISP-16': 'canny is multi-pass (PASSES=4) - needs pass-chained adapter',
 'ISP-17': 'framediff needs 2 frames - needs two-image adapter',
 'ISP-18': 'bilateral needs LUT load interface - deferred in isp_stream_harness',
 'ISP-19': 'remap needs coordinate LUT load - deferred',
 'INFRA-01': 'library primitives (elastic/fifo/stats) - exercised as harness plumbing on board',
 'INFRA-03': 'CDC primitives - no dual-clock board path yet',
 'INFRA-05': 'fixedpoint primitives exercised inside lms/agc builds; standalone adapters pending',
 'INFRA-07': 'test sources/sinks are host-facing tooling - exercised implicitly',
 'INFRA-04': 'tooling scope (coeff emitters, injection, wrappers, counters)',
 'INFRA-06': 'external-memory path - no DDR/SDRAM/PSRAM controller in repo; board scope blocked',
 'DSP-04':  'board-passed via dc->statistics production chain (reprogram x2)',
 'DSP-09':  'production-accepted via dc->statistics chain on remote board',
 'ISP-01':  'production-accepted via csc->morphology chain on remote board',
 'INFRA-02': 'production-accepted inside window-based chains',
}


def main():
    led = json.loads((HERE / 'requirements.json').read_text(encoding='utf-8'))
    pnr = pnr_summaries()
    board_paths = {}
    for run_dir, (rid, note) in BOARD.items():
        vd = ROOT / ART / run_dir
        v = json.loads((vd / 'verdict.json').read_text())
        assert v['status'] == 'PASS', (run_dir, v['status'])
        board_paths.setdefault(rid, []).append(
            (ART.as_posix() + '/' + run_dir, note, v))
    def add(row, field, path):
        if not (ROOT / path).exists():
            raise FileNotFoundError(path)
        if path not in row.setdefault(field, []):
            row[field].append(path)

    rep = []
    for row in led['requirements']:
        rid = row['id']
        ss = dict(rtl_sim='PASS' if row.get('simulation') else 'BLOCKED',
                  synthesis='PASS' if row.get('synthesis') else 'BLOCKED')
        # route/timing: aggregate pnr summaries for this req
        cases = [(k, v) for k, v in pnr.items() if k[0] == rid]
        if cases:
            oks = [d[2]['status'] == 'PASS' for _, d in cases]
            rt_status = 'PASS' if all(oks) else 'FAIL'
            for _, d in cases:
                add(row, 'route_timing', d[0])
        elif row.get('route_timing'):
            rt_status = 'PASS'  # pre-existing chain evidence
        else:
            rt_status = 'BLOCKED'
        ss['route_timing'] = rt_status
        # board
        if rid in board_paths:
            ss['board_test'] = 'PASS'
            ss['fx2_capture'] = 'PASS'
            for rel, note, v in board_paths[rid]:
                add(row, 'board_injection', rel + '/verdict.json')
                add(row, 'board_capture', rel + '/case_00/capture.sr')
                if 'reprogram' in rel:
                    add(row, 'board_reprogram', rel + '/verdict.json')
            if rid == 'DSP-05':
                # only mag_squared of the 4-module requirement is board-qualified
                ss['board_test'] = 'PARTIAL'
        elif rid in ('DSP-04', 'DSP-09', 'ISP-01', 'ISP-05', 'INFRA-02'):
            ss['board_test'] = 'PASS'
            ss['fx2_capture'] = 'PASS'
        elif rid == 'ISP-06':
            ss['board_test'] = 'FAIL'
            ss['fx2_capture'] = 'FAIL'
            for stale in ('scale_board_02', 'scale_board_03', 'scale_board_04'):
                p = f'cores/signal_processing/dsp_isp_library/artifacts/{stale}/failure.txt'
                if (ROOT / p).exists():
                    add(row, 'board_injection', p)
        else:
            ss['board_test'] = 'BLOCKED'
            ss['fx2_capture'] = 'BLOCKED'
        if rid in ('INFRA-04',):
            ss.update(rtl_sim='NA-tooling', synthesis='NA-tooling',
                      route_timing='NA-tooling', board_test='PASS',
                      fx2_capture='PASS')
            add(row, 'board_injection',
                ART.as_posix() + '/farrow_01/verdict.json')
            add(row, 'board_capture',
                ART.as_posix() + '/farrow_01/case_00/capture.sr')
        if rid == 'INFRA-06':
            ss.update(rtl_sim='PASS' if row.get('simulation') else 'BLOCKED',
                      synthesis='BLOCKED', route_timing='BLOCKED',
                      board_test='BLOCKED', fx2_capture='BLOCKED')
        ss['note'] = BLOCK_REASON.get(rid, '')
        row['stage_status'] = ss
        # promote status where every applicable stage is green and board ran
        if (ss['board_test'] == 'PASS' and ss['route_timing'] == 'PASS'
                and ss['fx2_capture'] == 'PASS'
                and row['status'] in ('仿真通过',)):
            row['status'] = '板测通过'
        rep.append(dict(id=rid, **ss))
    (HERE / 'stage_status_20260927.json').write_text(
        json.dumps(rep, ensure_ascii=False, indent=1))
    (HERE / 'requirements.json').write_text(
        json.dumps(led, ensure_ascii=False, indent=1) + '\n')
    for r in rep:
        print(r)


if __name__ == '__main__':
    main()
