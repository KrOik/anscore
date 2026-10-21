"""Full phase sample -> canonical transforms/PI -> applied protected PWM oracle."""
from datetime import datetime,timezone
import hashlib,json,math,shutil,subprocess
from pathlib import Path
from test_current_pi import step
from test_modulator import golden
ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir());P=ROOT/'cores/control/motor_foc';C=ROOT/'cores/acceleration/operator_library'
def truncdiv(a,b):return (1 if a>=0 else -1)*(abs(a)//b)
def main():
    out=ROOT/'artifacts/motor_foc_25k'/datetime.now(timezone.utc).strftime('foc_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    sources=[P/'rtl'/name for name in ['foc_current_step.v','current_transform.v','dq_current_pi.v','voltage_modulator.v','svpwm_duty.v','pwm3_atomic.v','pwm3_protection.v']]+[P/'tb/tb_foc_current_step.v']+[C/'rtl'/name for name in ['acc_clarke_s12.v','acc_park_s12.v','acc_ipi_pid_s12.v','acc_inv_park_s12.v']]+[C/'sim/mult12x12_model.v']
    tables=[C/'tables'/name for name in ['park_s12_sincos.mem','inv_park_s12_sincos.mem']]
    report=dict(status='FAIL',physical_measurement=False,sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources+tables+[Path(__file__).resolve(),P/'tools/test_current_pi.py',P/'tools/test_modulator.py']})
    print('Evidence='+str(out),flush=True)
    try:
        (out/'tables').mkdir()
        for table in tables:shutil.copyfile(table,out/'tables'/table.name)
        exe=out/'test.vvp'
        for label,cmd in [('compile',['iverilog','-g2012','-s','tb_foc_current_step','-o',str(exe)]+list(map(str,sources))),('run',['vvp',str(exe)])]:
            r=subprocess.run(cmd,cwd=out,capture_output=True,text=True,timeout=90);(out/(label+'.log')).write_text(r.stdout+r.stderr)
            if r.returncode:raise RuntimeError(r.stdout+r.stderr)
        actual=[tuple(map(int,line.split()[1:])) for line in r.stdout.splitlines() if line.startswith('FOC ')]
        expected=[];pa=pb=ind=inq=pd=pq=0
        for n in range(512):
            ia=pa;ib=(-pa*1024+pb*1774+1024)>>11;ic=-ia-ib;theta=0 if n<128 else 32 if n<256 else 64
            rd=0 if n<16 else 80 if n<256 else -60 if n<384 else 0
            rq=0 if n<16 else -60 if n<256 else 80 if n<384 else 0
            a=ia;b=((ia+2*ib)*1182+1024)>>11
            c=round(1024*math.cos(2*math.pi*theta/256));s=round(1024*math.sin(2*math.pi*theta/256))
            md=(a*c+b*s+512)>>10;mq=(-a*s+b*c+512)>>10
            ud,ind,pd,fd,ed=step(rd,md,ind,pd,n in (0,384),False)
            uq,inq,pq,fq,eq=step(rq,mq,inq,pq,n in (0,384),False)
            du,dv,dw,period,error,flags=golden(ud,uq,theta,256)
            diagnostics=fd|(fq<<12)|(flags<<30)|((ed|(eq<<1))<<34)
            expected.append((n,pa,pb,ia,ib,ic,md,mq,ud,uq,du,dv,dw,diagnostics))
            va=truncdiv((2*du-dv-dw)*2048,3*period);vb=truncdiv((dv-dw)*2048*1024,1774*period)
            da=40 if 192<=n<256 else 0;db=-32 if 192<=n<256 else 0
            pa+=(va-2*pa+da)>>4;pb+=(vb-2*pb+db)>>4
        if actual!=expected:
            mismatch=next(((a,b) for a,b in zip(actual,expected) if a!=b),('length',len(actual)))
            raise AssertionError(f'full FOC mismatch {mismatch}')
        errors={}
        for label,start,end,rd,rq in [('step',112,128,80,-60),('angle',176,192,80,-60),('disturbance',240,256,80,-60),('reversal',368,384,-60,80),('restart',496,512,0,0)]:
            errors[label]=max(max(abs(row[6]-rd),abs(row[7]-rq)) for row in actual[start:end])
            if errors[label]>5:raise AssertionError(f'FOC did not settle {label}:{errors[label]}')
        if 'PASS phase FOC applied PWM/plant/fault ownership' not in r.stdout:raise AssertionError('missing completion')
        report.update(status='PASS',samples=512,settled_max_error_counts=errors,scope='full phase RTL to applied protected PWM; averaged normalized numerical plant,not physical motor')
        print(f'PASS phaseFOC:512exact closed-loop states,applied PWM ownership,fault/flush/recovery,settled errors={errors}')
    except Exception as exc:report['reason']=str(exc);raise
    finally:(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':main()
