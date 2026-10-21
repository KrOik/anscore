"""Integrated PWM-driven averaged electrical/mechanical plant and independent oracle."""
from pathlib import Path
from datetime import datetime,timezone
import hashlib,json,shutil,subprocess
from test_current_pi import step
from test_modulator import golden
from test_foc import truncdiv
ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir());P=ROOT/'cores/control/motor_foc';C=ROOT/'cores/acceleration/operator_library'
def main():
    out=ROOT/'artifacts/motor_foc_25k'/datetime.now(timezone.utc).strftime('plant_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    sources=list((P/'rtl').glob('*.v'))+[P/'tb/tb_motor_plant.v']+[C/'rtl'/n for n in ['acc_clarke_s12.v','acc_park_s12.v','acc_inv_park_s12.v','acc_ipi_pid_s12.v']]+[C/'sim/mult12x12_model.v',ROOT/'cores/signal_processing/dsp/src/pid_core.v']+[ROOT/'cores/system/extended_library/src'/n for n in ['qei_dec.v','wdt_win.v']]
    tables=[C/'tables'/n for n in ['park_s12_sincos.mem','inv_park_s12_sincos.mem']]
    helpers=[P/'tools'/n for n in ['test_current_pi.py','test_modulator.py','test_foc.py']]
    report=dict(status='FAIL',physical_measurement=False,sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources+tables+helpers+[Path(__file__).resolve()]})
    print('Evidence='+str(out),flush=True)
    try:
        (out/'tables').mkdir()
        for table in tables:shutil.copyfile(table,out/'tables'/table.name)
        exe=out/'test.vvp'
        for label,cmd in [('compile',['iverilog','-g2012','-s','tb_motor_plant','-o',str(exe)]+list(map(str,sources))),('run',['vvp',str(exe)])]:
            r=subprocess.run(cmd,cwd=out,capture_output=True,text=True,timeout=120);(out/(label+'.log')).write_text(r.stdout+r.stderr)
            if r.returncode:raise RuntimeError(r.stdout+r.stderr)
        actual=[tuple(map(int,line.split()[1:])) for line in r.stdout.splitlines() if line.startswith('PLANT ')]
        expected=[];pa=pb=pq=mv=previous=target=integral=ind=inq=prevd=prevq=0;last_mode=3
        for n in range(2048):
            position=pq>>8;velocity=position-previous;previous=position
            mode=0 if n<32 else 1 if n<512 else 2 if n<1536 else 0 if n<1600 else 1
            if n==512:target=position+160
            if n==1024:target-=240
            ts=4 if n<288 else -3 if n<512 else 0
            speed=max(-32,min(32,(target-position)>>3 if mode==2 else ts))
            if mode==0:command=0
            else:
                if n==1600 or mode!=last_mode:integral=0
                e=max(-32768,min(32767,speed-velocity));integral=max(-2047,min(2047,integral+e))
                command=max(-256,min(256,4*e+(integral>>6)))
            ib=(-pa*1024+pb*1774+1024)>>11
            md=pa;mq=((pa+2*ib)*1182+1024)>>11
            vd,ind,prevd,_,_=step(0,md,ind,prevd,n==1600,False)
            vq,inq,prevq,_,_=step(command,mq,inq,prevq,n==1600,False)
            du,dv,dw,_,err,_=golden(vd,vq,0,256)
            if err:raise AssertionError('oracle modulation error')
            expected.append((n,mode,position,velocity,target,ts,pa,pb,md,mq,vd,vq,du,dv,dw,pq,mv,n+1))
            va=truncdiv((2*du-dv-dw)*2048,3*256);vb=truncdiv((dv-dw)*2048*1024,1774*256)
            pa+=(va-2*pa)>>4;pb+=(vb-2*pb)>>4
            load=8*256 if 192<=n<256 else 0
            mv+=(pb*256-4*mv-load)>>7;pq+=mv;last_mode=mode
        if actual!=expected:
            mismatch=next(((a,b) for a,b in zip(actual,expected) if a!=b),('length',len(actual)))
            raise AssertionError(f'integrated plant mismatch {mismatch}')
        metrics={}
        for label,start,end,kind,limit in [('speed',176,192,'speed',2),('disturbance',272,288,'speed',2),('reverse',496,512,'speed',2),('position',1008,1024,'position',10),('position_reverse',1520,1536,'position',10),('restart',2032,2048,'speed',2)]:
            error=max(abs(x[2]-x[4]) if kind=='position' else abs(x[3]-x[5]) for x in actual[start:end]);metrics[label]=error
            if error>limit:raise AssertionError(f'{label} unsettled {error}>{limit}')
        if 'PASS integrated PWM/current/mechanical/QEI plant' not in r.stdout:raise AssertionError('missing completion')
        report.update(status='PASS',samples=2048,sample_period_clocks=1024,settled_max_errors=metrics,scope='averaged alpha-beta electrical and mechanical surrogate at supplied theta0,actual applied duties/QEI;not physical motor')
        print('PASS integrated plant:2048 exact states; settled='+str(metrics))
    except Exception as exc:report['reason']=str(exc);raise
    finally:(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':main()
