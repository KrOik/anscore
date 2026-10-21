"""Verify complete carrier duty counts, atomic updates and protected gates."""
from datetime import datetime,timezone
import hashlib,json,subprocess
from pathlib import Path
ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir());P=ROOT/'cores/control/motor_foc'
def main():
    out=ROOT/'artifacts/motor_foc_25k'/datetime.now(timezone.utc).strftime('atomic_pwm_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    sources=[P/'rtl/pwm3_atomic.v',P/'rtl/pwm3_protection.v',P/'tb/tb_pwm3_atomic.v']
    report=dict(status='FAIL',physical_measurement=False,sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources+[Path(__file__).resolve()]})
    print('Evidence='+str(out),flush=True)
    try:
        exe=out/'test.vvp'
        for label,cmd in [('compile',['iverilog','-g2012','-s','tb_pwm3_atomic','-o',str(exe)]+list(map(str,sources))),('run',['vvp',str(exe)])]:
            r=subprocess.run(cmd,cwd=ROOT,capture_output=True,text=True,timeout=60);(out/(label+'.log')).write_text(r.stdout+r.stderr)
            if r.returncode:raise RuntimeError(r.stdout+r.stderr)
        rows=[tuple(map(int,line.split()[1:])) for line in r.stdout.splitlines() if line.startswith('PWM ')]
        prior=None;frame=[];complete=0;seen=set()
        for row in rows:
            cycle,en,id,counter,period,u,v,w,dead,raw,hi,lo,fault=row
            expected_raw=sum(int(en and counter<d)<<g for g,d in enumerate((u,v,w))) if id else 0
            if raw!=expected_raw or hi&lo or ((fault or not en)and(hi or lo)):raise AssertionError('comparator/protection mismatch')
            if prior and en and prior[1] and id:
                if id!=prior[2]:
                    if prior[3]!=prior[4]-1 or counter!=0:raise AssertionError('mid-carrier command update')
                elif counter!=(prior[3]+1)%period:raise AssertionError('carrier cadence')
            if en and counter==0 and id:frame=[]
            if en and id:frame.append(row)
            else:frame=[]
            if len(frame)==period and frame[0][3]==0 and counter==period-1:
                if any(x[2]!=id or x[4:9]!=row[4:9] for x in frame):raise AssertionError('mixed carrier parameters')
                counts=[sum(bool(x[9]&(1<<g)) for x in frame) for g in range(3)]
                if counts!=[u,v,w]:raise AssertionError('raw duty count')
                complete+=1;seen.add(id);frame=[]
            prior=row
        if not {1,2,4}<=seen or complete<12 or 'PASS atomic PWM carrier/protection' not in r.stdout:raise AssertionError('coverage/completion')
        report.update(status='PASS',sampled_cycles=len(rows),complete_carriers=complete,scope='digital atomic carrier plus real protection;not physical gates/load')
        print(f'PASS atomicPWM:{complete}exact carriers,{len(rows)}cycles,threeparameter sets,invalid/fault/recovery')
    except Exception as exc:report['reason']=str(exc);raise
    finally:(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':main()
