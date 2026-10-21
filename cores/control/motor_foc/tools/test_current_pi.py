"""Independent stateful PI oracle against an RTL-driven dq numerical plant."""
from datetime import datetime,timezone
import hashlib,json,subprocess
from pathlib import Path
ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir());P=ROOT/'cores/control/motor_foc';C=ROOT/'cores/acceleration/operator_library'
def step(reference,current,integral,previous,restart,freeze):
    e=max(-2048,min(2047,reference-current));i0=0 if restart else integral;prev=0 if restart else previous
    delta=e-prev;derivative=max(-2048,min(2047,delta));candidate=i0 if freeze else max(-2048,min(2047,i0+e))
    rail=int(not freeze and candidate!=i0+e)
    value=((e*8+8)>>4)+((candidate*4+8)>>4)
    voltage=max(-1024,min(1023,value));high=int(value>1023);low=int(value< -1024)
    wind=int((high and e>0)or(low and e<0));committed=i0 if wind and not freeze else candidate
    flags=high|(low<<1)|(rail<<2)|(int(delta!=derivative)<<3)|(wind<<4)|(int(freeze)<<5)|(int(restart)<<6)|(1<<7)|(4<<8)
    return voltage,committed,e,flags,int(high or low or rail)
def main():
    out=ROOT/'artifacts/motor_foc_25k'/datetime.now(timezone.utc).strftime('current_pi_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    sources=[P/'rtl/dq_current_pi.v',P/'tb/tb_dq_current_pi.v',C/'rtl/acc_ipi_pid_s12.v',C/'sim/mult12x12_model.v']
    report=dict(status='FAIL',physical_measurement=False,sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources+[Path(__file__).resolve()]})
    print('Evidence='+str(out),flush=True)
    try:
        exe=out/'test.vvp'
        for label,cmd in [('compile',['iverilog','-g2012','-s','tb_dq_current_pi','-o',str(exe)]+list(map(str,sources))),('run',['vvp',str(exe)])]:
            r=subprocess.run(cmd,cwd=out,capture_output=True,text=True,timeout=60);(out/(label+'.log')).write_text(r.stdout+r.stderr)
            if r.returncode:raise RuntimeError(r.stdout+r.stderr)
        actual=[tuple(map(int,line.split()[1:])) for line in r.stdout.splitlines() if line.startswith('PI ')]
        expected=[];cd=cq=ind=inq=prevd=prevq=0;wind_samples=0
        for n in range(1024):
            rd=0 if n<64 else 120 if n<384 else -80 if n<512 else 1500 if n<576 else 0 if n<832 else 100
            rq=0 if n<64 else -160 if n<384 else 90 if n<512 else -1500 if n<576 else 0 if n<832 else -100
            dd=80 if 256<=n<384 else 0;dq=-64 if 256<=n<384 else 0
            restart=n in (0,832);freeze=320<=n<336
            ud,ind,prevd,fd,ef_d=step(rd,cd,ind,prevd,restart,freeze)
            uq,inq,prevq,fq,ef_q=step(rq,cq,inq,prevq,restart,freeze)
            expected.append((n,rd,rq,cd,cq,ud,uq,ind,inq,fd,fq,ef_d|(ef_q<<1),0))
            wind_samples+=bool((fd|fq)&16)
            cd+=(ud-2*cd+dd)>>4;cq+=(uq-2*cq+dq)>>4
        if actual!=expected:
            mismatch=next(((a,b) for a,b in zip(actual,expected) if a!=b),('length',len(actual)))
            raise AssertionError(f'PI/plant state mismatch {mismatch}')
        windows={}
        for label,start,end in [('step',240,256),('disturbance',368,384),('reversal',496,512),('recovery',816,832),('restart',1008,1024)]:
            error=max(max(abs(row[1]-row[3]),abs(row[2]-row[4])) for row in actual[start:end]);windows[label]=error
            if error>3:raise AssertionError(f'{label} not settled: {error}')
        if wind_samples<20 or 'PASS dq current PI numerical plant' not in r.stdout:raise AssertionError('missing antiwindup/completion')
        report.update(status='PASS',samples=1024,antiwindup_samples=wind_samples,settled_max_error_counts=windows,scope='RTL dq PI closed on first-order numerical plant,not full phase FOC/PWM/motor')
        print(f'PASS dq PI plant:1024exact states,{wind_samples}antiwindup samples,settlederrors={windows},clipping/stalls/restart')
    except Exception as exc:report['reason']=str(exc);raise
    finally:(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':main()
