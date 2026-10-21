"""Source raster/cadence oracle, restart, stalls and invalid config tests."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
P = ROOT / 'cores/image_processing/isp_stream'


def main():
    sources = [P / 'rtl/virtual_raw_source.v', P / 'tb/tb_virtual_raw_source.v']
    out = ROOT / 'artifacts/isp_stream_25k' / datetime.now(timezone.utc).strftime('virtual_source_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    report = {'status': 'IN_PROGRESS', 'sources': {str(s.relative_to(ROOT)): hashlib.sha256(s.read_bytes()).hexdigest()
              for s in sources + [Path(__file__).resolve()]}, 'cases': []}
    try:
        for bits in (8, 10, 12):
            exe = out / f'raw{bits}.vvp'
            run = subprocess.run(['iverilog', '-g2012', '-s', 'tb_virtual_raw_source', '-P',
                f'tb_virtual_raw_source.RAW_BITS={bits}', '-o', str(exe)] + list(map(str, sources)), capture_output=True, text=True)
            (out / f'compile{bits}.log').write_text(run.stdout+run.stderr)
            if run.returncode:
                raise RuntimeError(run.stderr)
            run = subprocess.run(['vvp', str(exe)], capture_output=True, text=True, timeout=180)
            (out / f'run{bits}.log').write_text(run.stdout+run.stderr)
            if run.returncode or f'PASS virtual RAW source bits={bits}' not in run.stdout:
                raise RuntimeError(run.stdout+run.stderr)
            report['cases'].append({'raw_bits': bits, 'status': 'PASS'})
            print(run.stdout)
        report['status'] = 'PASS'
    except Exception as exc:
        report.update(status='FAIL', reason=str(exc))
        raise
    finally:
        (out / 'summary.json').write_text(json.dumps(report, indent=2)+'\n')
        print('Evidence='+str(out))


if __name__ == '__main__':
    main()
