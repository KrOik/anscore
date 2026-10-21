"""Independent synchronized Gray transition and snapshot velocity model."""
from datetime import datetime,timezone
import hashlib,json,subprocess
from pathlib import Path
ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir());P=ROOT/'cores/control/motor_foc'
def signed32(x):return ((x+2**31)%2**32)-2**31
def main():
    out=ROOT/'artifacts/motor_foc_25k'/datetime.now(timezone.utc).strftime('encoder_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    sources=[P/'rtl/encoder_feedback.v',P/'tb/tb_encoder_feedback.v',ROOT/'cores/system/extended_library/src/qei_dec.v']
    report=dict(status='FAIL',physical_measurement=False,sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources+[Path(__file__).resolve()]})
    print('Evidence='+str(out),flush=True)
    try:
        exe=out/'test.vvp'
        for label,cmd in [('compile',['iverilog','-g2012','-s','tb_encoder_feedback','-o',str(exe)]+list(map(str,sources))),('run',['vvp',str(exe)])]:
            r=subprocess.run(cmd,cwd=ROOT,capture_output=True,text=True,timeout=60);(out/(label+'.log')).write_text(r.stdout+r.stderr)
            if r.returncode:raise RuntimeError(r.stdout+r.stderr)
        rows=[tuple(map(int,line.split()[1:])) for line in r.stdout.splitlines() if line.startswith('QEI ')]
        sync0=sync1=previous=previous_index=delayed_reset=count=il=ie=baseline=have=time=seq=error=invalid=0
        direction=1;vv=pos=speed=stamp=0;illegal_total=0;forward={(0,2),(2,3),(3,1),(1,0)}
        for n,row in enumerate(rows):
            qa,qb,index,ir,sample,clear,*actual=row
            ab=sync1&3;idx=(sync1>>2)&1;illegal=(ab^previous)==3;rebase=ie and delayed_reset
            old_count=count
            if sample:
                pos=signed32(old_count);stamp=time;seq+=1
                vv=int(bool(have and not rebase));speed=signed32(old_count-baseline) if vv else 0
            if rebase:have=0
            if sample:baseline=old_count;have=int(not rebase)
            elif rebase:baseline=old_count
            if clear:error=invalid=0
            if illegal:error=1;invalid+=1;illegal_total+=1
            rising=idx and not previous_index
            delta=1 if (previous,ab)in forward else -1 if (ab,previous)in forward else 0
            if rising:il=old_count
            if rising and ir:count=0
            else:
                count=(count+delta)%2**32
                if delta:direction=int(delta>0)
            ie=int(bool(rising));step=int(ab!=previous)
            expected=[count,il,direction,step,ie,sample,vv,pos,speed,stamp,seq,error,invalid]
            if actual!=expected:raise AssertionError(f'cycle{n}: {actual} != {expected}')
            previous=ab;previous_index=idx;delayed_reset=ir;sync1=sync0;sync0=(index<<2)|(qa<<1)|qb;time+=1
        if len(rows)!=1000 or illegal_total<3 or error or 'PASS encoder feedback' not in r.stdout:raise AssertionError('coverage/completion')
        report.update(status='PASS',cycles=len(rows),snapshots=seq,illegal_transitions_injected=illegal_total,scope='synchronized canonical QEI/delta snapshots;not physical encoder/speed-position control')
        print(f'PASS QEI:{len(rows)}exact cycles,{seq}snapshots,forward/reverse,index/rebase,wrap,invalid transitions/clear')
    except Exception as exc:report['reason']=str(exc);raise
    finally:(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':main()
