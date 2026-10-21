"""Full-chain no-stall latency comparison across all64 actual CSR mode runs."""
from datetime import datetime,timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
from test_all_modes import ROOT,P,golden_frame


def main():
    baseline=ROOT/'artifacts/isp_stream_25k/all_modes_20261020T183333608166Z/summary.json'
    sources=[ROOT/n for n in json.loads(baseline.read_text())['sources'] if n.endswith('.v')]
    sources.append(P/'tb/tb_isp_mode_latency.v')
    out=ROOT/'artifacts/isp_stream_25k'/datetime.now(timezone.utc).strftime('mode_latency_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    report=dict(status='FAIL',physical_measurement=False,sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources+[Path(__file__).resolve(),P/'tools/test_all_modes.py']})
    try:
        exe=out/'test.vvp'
        build=subprocess.run(['iverilog','-g2012','-s','tb_isp_mode_latency','-o',str(exe)]+list(map(str,sources)),capture_output=True,text=True)
        (out/'compile.log').write_text(build.stdout+build.stderr)
        if build.returncode:raise RuntimeError(build.stderr)
        run=subprocess.run(['vvp',str(exe),'+output='+str(out/'pixels.bin')],capture_output=True,text=True,timeout=60)
        (out/'run.log').write_text(run.stdout+run.stderr)
        if run.returncode or 'PASS all64' not in run.stdout:raise RuntimeError(run.stdout+run.stderr)
        rows=[tuple(map(int,r)) for r in re.findall(r'MODE_LATENCY version=(\d+) first=(\d+) tail=(\d+) input_span=(\d+) output_span=(\d+)',run.stdout)]
        if len(rows)!=64 or [r[0] for r in rows]!=list(range(1,65)):raise RuntimeError('missing mode timing')
        if len({r[1:] for r in rows})!=1:raise RuntimeError('mode-dependent no-stall pipeline timing: '+str(rows))
        expected=b''.join(golden_frame(m)[0] for m in range(64))
        actual=(out/'pixels.bin').read_bytes()
        if actual!=expected:raise RuntimeError('no-stall pixel/marker mismatch')
        report.update(status='PASS',modes=64,output_pixels=576,
                      first_output_latency=rows[0][1],tail_latency=rows[0][2],input_span=rows[0][3],output_span=rows[0][4],
                      output_sha256=hashlib.sha256(actual).hexdigest(),scope='fixed7x7 no-stall pipeline timing; not command latency or physical II')
        print('PASS all64 equal full-chain pipeline timing: '+str(rows[0][1:]))
    except Exception as exc:
        report['reason']=str(exc);raise
    finally:
        (out/'summary.json').write_text(json.dumps(report,indent=2)+'\n');print('Evidence='+str(out))


if __name__=='__main__':main()
