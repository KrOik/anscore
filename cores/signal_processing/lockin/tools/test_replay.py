"""Run real source/core replay owner through failure/recovery sequences."""
from datetime import datetime,timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir());P=ROOT/'cores/signal_processing/lockin'


def main():
    out=ROOT/'artifacts/lockin_dsp_25k'/datetime.now(timezone.utc).strftime('replay_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    sources=sorted((P/'rtl').glob('*.v'))+[P/'tb/tb_lockin_replay.v',ROOT/'cores/signal_processing/dsp/src/dds_nco.v',ROOT/'cores/signal_processing/dsp/src/cordic.v',ROOT/'cores/system/stream_bus_library/rtl/sys_timestamp64.v']
    report=dict(status='FAIL',physical_measurement=False,sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources+[Path(__file__).resolve(),P/'tools/gen_vectors.py']})
    try:
        vec=out/'vectors';subprocess.run([sys.executable,str(P/'tools/gen_vectors.py'),'--output',str(vec)],check=True)
        exe=out/'test.vvp'
        r=subprocess.run(['iverilog','-g2012','-s','tb_lockin_replay','-Ptb_lockin_replay.SIN_FILE="'+(vec/'sine.mem').as_posix()+'"',
          '-Ptb_lockin_replay.COS_FILE="'+(vec/'cosine.mem').as_posix()+'"','-o',str(exe)]+list(map(str,sources)),capture_output=True,text=True)
        (out/'compile.log').write_text(r.stdout+r.stderr)
        if r.returncode:raise RuntimeError(r.stderr)
        r=subprocess.run(['vvp',str(exe)],capture_output=True,text=True,timeout=60);(out/'run.log').write_text(r.stdout+r.stderr)
        if r.returncode or 'PASS replay finiteabort' not in r.stdout:raise RuntimeError('\n'.join((r.stdout+r.stderr).splitlines()[-12:]))
        # Independent exact IQ for the accepted live cosine samples.
        cfg=json.loads((vec/'cases.json').read_text())[0]
        cos=[int(v,16) for v in (vec/'cosine.mem').read_text().split()];cos=[v-65536 if v&32768 else v for v in cos]
        sin=[int(v,16) for v in (vec/'sine.mem').read_text().split()];sin=[v-65536 if v&32768 else v for v in sin]
        expected=[]
        for lane in range(4):
            x=[cfg['amplitudes'][lane]*cos[(n+cfg['phases_indices'][lane])%256]>>15 for n in range(256)]
            expected.append((sum(a*b for a,b in zip(x,cos))>>23,-sum(a*b for a,b in zip(x,sin))>>23))
        results=re.findall(r'REPLAY_RESULT run=(\d+) lane=(\d+) i=(-?\d+) q=(-?\d+)',r.stdout)
        if len(results)!=20:raise RuntimeError('missing successful runs')
        for run,lane,i,q in results:
            if (int(i),int(q))!=expected[int(lane)]:raise RuntimeError('replay golden IQ')
        report.update(status='PASS',successful_runs=5,failure_completions=5,scope='live digital simulation; physical/JTAG acceptance pending')
        print('PASS replay:5 clean runs,5 explicit failures,no partial result,post-abort recovery')
    except Exception as exc:report['reason']=str(exc);raise
    finally:(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n');print('Evidence='+str(out))


if __name__=='__main__':main()
