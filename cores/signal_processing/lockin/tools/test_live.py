"""Actual common-clock virtual ADC->lock-in,exact samples/IQ and error table."""
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
    out=ROOT/'artifacts/lockin_dsp_25k'/datetime.now(timezone.utc).strftime('live_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    sources=[P/'rtl/lockin4.v',P/'rtl/virtual_adc4.v',P/'tb/tb_live_adc_lockin.v',ROOT/'cores/signal_processing/dsp/src/dds_nco.v',
             ROOT/'cores/signal_processing/dsp/src/cordic.v',ROOT/'cores/system/stream_bus_library/rtl/sys_timestamp64.v']
    report=dict(status='FAIL',physical_measurement=False,sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources+[Path(__file__).resolve(),P/'tools/gen_vectors.py']})
    try:
        vec=out/'vectors';subprocess.run([sys.executable,str(P/'tools/gen_vectors.py'),'--output',str(vec)],check=True)
        exe=out/'test.vvp'
        r=subprocess.run(['iverilog','-g2012','-s','tb_live_adc_lockin','-Ptb_live_adc_lockin.SIN_FILE="'+(vec/'sine.mem').as_posix()+'"',
            '-Ptb_live_adc_lockin.COS_FILE="'+(vec/'cosine.mem').as_posix()+'"','-o',str(exe)]+list(map(str,sources)),capture_output=True,text=True)
        (out/'compile.log').write_text(r.stdout+r.stderr)
        if r.returncode:raise RuntimeError(r.stderr)
        r=subprocess.run(['vvp',str(exe)],capture_output=True,text=True,timeout=60);(out/'run.log').write_text(r.stdout+r.stderr)
        if r.returncode or 'PASS live4ADC' not in r.stdout:raise RuntimeError('\n'.join((r.stdout+r.stderr).splitlines()[-6:]))
        cfgs=json.loads((vec/'cases.json').read_text());cos=[round(32767*math.cos(2*math.pi*i/256)) for i in range(256)]
        sin=[round(32767*math.sin(2*math.pi*i/256)) for i in range(256)]
        sums=[[[0,0] for _ in range(4)] for _ in range(3)];times=[[] for _ in range(3)]
        rows=re.findall(r'ADC_SAMPLE run=(\d+) index=(\d+) time=(\d+) data=([0-9a-fA-F]+)',r.stdout)
        if len(rows)!=768:raise RuntimeError('sample count')
        for run,index,timestamp,packed in rows:
            run,index,timestamp,packed=int(run),int(index),int(timestamp),int(packed,16)
            cfg=cfgs[run];phase=index*cfg['bins']%256
            if index!=len(times[run]):raise RuntimeError('duplicate/skipped sample')
            times[run].append(timestamp)
            for lane in range(4):
                value=(packed>>(16*lane))&65535;value=value-65536 if value&32768 else value
                expected=cfg['amplitudes'][lane]*cos[(phase+cfg['phases_indices'][lane])%256]>>15
                if value!=expected:raise RuntimeError('virtual ADC sample mismatch')
                sums[run][lane][0]+=value*cos[phase];sums[run][lane][1]-=value*sin[phase]
        table=[];results=re.findall(r'LIVE_RESULT run=(\d+) lane=(\d+) i=(-?\d+) q=(-?\d+) amplitude=(\d+) phase=(-?\d+) first=(\d+) last=(\d+)',r.stdout)
        if len(results)!=12:raise RuntimeError('result count')
        for row in results:
            run,lane,i,q,amp,phase,first,last=map(int,row);cfg=cfgs[run];period=(4,16,37)[run]
            if (i,q)!=tuple(v>>23 for v in sums[run][lane]):raise RuntimeError('live IQ mismatch')
            if first!=times[run][0] or last!=times[run][-1] or any(b-a!=period for a,b in zip(times[run],times[run][1:])):raise RuntimeError('live timestamp cadence')
            pe=(phase/16384-cfg['phases_indices'][lane]*2*math.pi/256+math.pi)%(2*math.pi)-math.pi
            ae=amp-cfg['amplitudes'][lane]
            if abs(ae)>12 or abs(pe)>0.06:raise RuntimeError('live amplitude/phase limits')
            table.append(dict(run=run,lane=lane,sample_period_clocks=period,cycles_per_sample=cfg['bins']/256,
                              expected_amplitude=cfg['amplitudes'][lane],amplitude=amp,amplitude_error=ae,phase_error_radians=pe,i=i,q=q,first=first,last=last))
        with (out/'error_table.csv').open('w',newline='') as f:
            writer=csv.DictWriter(f,fieldnames=list(table[0]));writer.writeheader();writer.writerows(table)
        report.update(status='PASS',accepted_vectors=768,error_table=table,scope='live common-clock digital simulation; no physical ADC/board measurement')
        print('PASS virtual ADC->lockin:768 actualclock vectors,exact samples/IQ/timestamps,12 error rows')
    except Exception as exc:report['reason']=str(exc);raise
    finally:(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n');print('Evidence='+str(out))


if __name__=='__main__':main()
