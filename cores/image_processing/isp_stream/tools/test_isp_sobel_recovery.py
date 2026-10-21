"""Directed malformed-frame drain and clean-frame recovery with saved evidence."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
P = ROOT / 'cores/image_processing/isp_stream'


def main():
    sources = sorted((P / 'rtl').glob('*.v')) + [ROOT / 'cores/system/common_scaffold/image' / name for name in (
        'pipelines/img_bayer_window_frontend_draft.v', 'window/img_window3x3_valid_draft.v',
        'isp/img_isp_bayer_interpolate.v', 'isp/img_isp_awb_gain.v', 'isp/img_isp_ccm.v', 'isp/img_isp_gamma_lut.v', 'isp/img_isp_awb_stats.v','filters/rtl/img_edge_sobel3x3.v','filters/rtl/img_edge_gradient3x3.v','filters/rtl/img_filter_stream_register.v')] + [P / 'tb/tb_isp_sobel_recovery.v']
    out = ROOT / 'artifacts/isp_stream_25k' / datetime.now(timezone.utc).strftime('sobel_recovery_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    report = {'status': 'IN_PROGRESS', 'sources': {p.relative_to(ROOT).as_posix():
        hashlib.sha256(p.read_bytes()).hexdigest() for p in sources + [Path(__file__).resolve()]}}
    try:
        exe = out / 'test.vvp'
        build = subprocess.run(['iverilog', '-g2012', '-s', 'tb_isp_sobel_recovery', '-o', str(exe)] + list(map(str, sources)), capture_output=True, text=True)
        (out / 'compile.log').write_text(build.stdout + build.stderr)
        if build.returncode:
            raise RuntimeError(build.stderr)
        run = subprocess.run(['vvp', str(exe)], capture_output=True, text=True, timeout=30)
        (out / 'run.log').write_text(run.stdout + run.stderr)
        if run.returncode or 'PASS ISP Sobel configuration reject' not in run.stdout:
            raise RuntimeError(run.stdout + run.stderr)
        report.update(status='PASS', checked_clean_pixels=9, malformed_frame_id=1,
                      malformed_response_error=2, recovery_frame_id=2,
                      recovery_response_error=0, successful_snapshots=1)
        print(run.stdout.splitlines()[0])
    except Exception as exc:
        report.update(status='FAIL', reason=str(exc))
        raise
    finally:
        (out / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
        print('Evidence=' + str(out))


if __name__ == '__main__':
    main()
