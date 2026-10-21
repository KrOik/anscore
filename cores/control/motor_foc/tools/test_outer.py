"""Independent three-mode controller and numerical mechanical plant oracle."""
from datetime import datetime,timezone
import hashlib,json,subprocess
from pathlib import Path
ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir());P=ROOT/'cores/control/motor_foc'
def main():
    out=ROOT/'artifacts/motor_foc_25k'/datetime.now(timezone.utc).strftime('outer_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    sources=[P/'rtl/motor_outer_loop.v',P/'tb/tb_motor_outer_loop.v',ROOT/'cores/signal_processing/dsp/src/pid_core.v']
    report=dict(status='FAIL',physical_measurement=False,sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources+[Path(__file__).resolve()]})
    print('Evidence='+str(out),flush=True)
    try:
        exe=out/'test.vvp'
        for label,cmd in [('compile',['iverilog','-g2012','-s','tb_motor_outer_loop','-o',str(exe)]+list(map(str,sources))),('run',['vvp',str(exe)])]:
            r=subprocess.run(cmd,cwd=out,capture_output=True,text=True,timeout=60);(out/(label+'.log')).write_text(r.stdout+r.stderr)
            if r.returncode:raise RuntimeError(r.stdout+r.stderr)
        actual=[tuple(map(int,line.split()[1:])) for line in r.stdout.splitlines() if line.startswith('OUTER ')]
        expected=[];pq=vq=previous=target=integral=0;last_mode=3
        for n in range(1024):
            pos=pq>>8;vel=pos-previous;previous=pos
            mode=0 if n<32 else 1 if n<256 else 2 if n<768 else 0 if n<832 else 1
            if n==256:target=pos+400
            if n==512:target-=600
            ts=12 if n<160 else -8 if n<256 else 0
            desired=(target-pos)>>3 if mode==2 else ts;speed=max(-32,min(32,desired))
            clips=4 if desired!=speed else 0;reset=int(n==832 or mode!=last_mode)
            if mode==0:command=0
            else:
                if reset:integral=0
                e=max(-32768,min(32767,speed-vel));integral=max(-2047,min(2047,integral+e))
                command=max(-256,min(256,4*e+(integral>>2)))
            expected.append((n,mode,pos,vel,target,ts,speed,command,clips,reset if mode else 0,vq))
            load=32*256 if 96<=n<128 else 0
            vq+=(command*256-4*vq-load)>>5;pq+=vq;last_mode=mode
        if actual!=expected:
            mismatch=next(((a,b) for a,b in zip(actual,expected) if a!=b),('length',len(actual)))
            raise AssertionError(f'outer mode/plant mismatch {mismatch}')
        metrics={}
        for label,start,end,kind,tolerance in [('speed',80,96,'speed',2),('reversal',240,256,'speed',2),('position',496,512,'position',10),('position_reverse',752,768,'position',10),('restart',1008,1024,'speed',2)]:
            error=max(abs(row[2]-row[4]) if kind=='position' else abs(row[3]-row[6]) for row in actual[start:end]);metrics[label]=error
            if error>tolerance:raise AssertionError(f'{label} unsettled:{error}')
        if 'PASS motor outer modes/plant/ownership' not in r.stdout:raise AssertionError('missing completion')
        report.update(status='PASS',samples=1024,settled_max_errors=metrics,scope='outer current/speed/position controller with normalized mechanical plant;not integrated phaseFOC/QEI')
        print(f'PASS outer modes:1024exact states,mode reset/held outputs,invalid feedback/mode/overflow;settled={metrics}')
    except Exception as exc:report['reason']=str(exc);raise
    finally:(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':main()
