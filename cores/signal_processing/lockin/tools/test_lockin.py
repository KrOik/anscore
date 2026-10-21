"""Four-channel exact I/Q and float amplitude/phase error table from RTL."""
from datetime import datetime,timezone
import csv
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess
import sys

ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir());P=ROOT/'cores/signal_processing/lockin'


def main():
    out=ROOT/'artifacts/lockin_dsp_25k'/datetime.now(timezone.utc).strftime('lockin_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    sources=[P/'rtl/lockin4.v',P/'tb/tb_lockin4.v',ROOT/'cores/signal_processing/dsp/src/dds_nco.v',ROOT/'cores/signal_processing/dsp/src/cordic.v']
    report=dict(status='FAIL',physical_measurement=False,sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources+[Path(__file__).resolve(),P/'tools/gen_vectors.py']})
    try:
        vec=out/'vectors';subprocess.run([sys.executable,str(P/'tools/gen_vectors.py'),'--output',str(vec)],check=True)
        exe=out/'test.vvp'
        r=subprocess.run(['iverilog','-g2012','-s','tb_lockin4','-Ptb_lockin4.SIN_FILE="'+(vec/'sine.mem').as_posix()+'"',
                          '-Ptb_lockin4.COS_FILE="'+(vec/'cosine.mem').as_posix()+'"','-o',str(exe)]+list(map(str,sources)),capture_output=True,text=True)
        (out/'compile.log').write_text(r.stdout+r.stderr)
        if r.returncode:raise RuntimeError(r.stderr)
        r=subprocess.run(['vvp',str(exe),'+memdir='+str(vec)],capture_output=True,text=True,timeout=60)
        (out/'run.log').write_text(r.stdout+r.stderr)
        if r.returncode or 'PASS lockin4' not in r.stdout:raise RuntimeError(r.stdout+r.stderr)
        rows=[tuple(map(int,row)) for row in re.findall(r'LOCKIN case=(\d+) lane=(\d+) i=(-?\d+) q=(-?\d+) amplitude=(\d+) phase=(-?\d+) first=(\d+) last=(\d+) error=(\d+)',r.stdout)]
        cases=json.loads((vec/'cases.json').read_text());table=[]
        if len(rows)!=36:raise RuntimeError('missing result rows')
        for case,lane,i,q,amplitude,phase,first,last,error in rows:
            if case>=3:
                if i!=0 or q!=0 or amplitude!=0 or phase!=0:raise RuntimeError('zero/rejection output')
                continue
            cfg=cases[case]
            if (i,q)!=(cfg['expected_i'][lane],cfg['expected_q'][lane]):raise RuntimeError(f'IQ mismatch {case}/{lane}: {i}/{q}')
            if first!=100000+case*1000000 or last!=first+255000:raise RuntimeError('sample timestamps')
            expected_phase=cfg['phases_indices'][lane]*2*math.pi/256
            phase_error=(phase/16384-expected_phase+math.pi)%(2*math.pi)-math.pi
            amp_error=amplitude-cfg['amplitudes'][lane]
            if abs(amp_error)>12 or abs(phase_error)>0.06:raise RuntimeError('amplitude/phase error outside specification')
            table.append(dict(case=case,lane=lane,frequency_cycles_per_sample=cfg['bins']/256,
                expected_amplitude=cfg['amplitudes'][lane],measured_amplitude=amplitude,amplitude_error=amp_error,
                expected_phase_radians=(expected_phase+math.pi)%(2*math.pi)-math.pi,
                measured_phase_radians=phase/16384,phase_error_radians=phase_error,i=i,q=q))
        with (out/'error_table.csv').open('w',newline='') as f:
            writer=csv.DictWriter(f,fieldnames=list(table[0]));writer.writeheader();writer.writerows(table)
        report.update(status='PASS',channels=4,coherent_cases=3,error_table=table,
                      scope='digital synthetic stream RTL simulation; no ADC/board physical measurement')
        print('PASS4channel DDS/IQ/integration/CORDIC:12 amplitude/phase error rows')
    except Exception as exc:report['reason']=str(exc);raise
    finally:(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n');print('Evidence='+str(out))


if __name__=='__main__':main()
