"""Independent raster/sync and counter oracle for three parallel outputs."""
from datetime import datetime,timezone
import hashlib
import json
from pathlib import Path
import subprocess

ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir());P=ROOT/'cores/image_processing/video_compositor'
def main():
    out=ROOT/'artifacts/video_compositor_25k'/datetime.now(timezone.utc).strftime('multi_timing_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    sources=[P/'rtl/multi_output_timing.v',P/'tb/tb_multi_output_timing.v',ROOT/'cores/system/common_scaffold/image/video_scanout/video_timing_generator.sv']
    report=dict(status='FAIL',physical_measurement=False,sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources+[Path(__file__).resolve()]})
    print('Evidence='+str(out),flush=True)
    try:
        exe=out/'test.vvp'
        for label,cmd in [('compile',['iverilog','-g2012','-s','tb_multi_output_timing','-o',str(exe)]+list(map(str,sources))),('run',['vvp',str(exe)])]:
            r=subprocess.run(cmd,cwd=ROOT,capture_output=True,text=True,timeout=60);(out/(label+'.log')).write_text(r.stdout+r.stderr)
            if r.returncode:raise RuntimeError(r.stdout+r.stderr)
        # ha,hfront,hsync,hback,va,vfront,vsync,vback,hpol,vpol
        configs=[(4,1,1,2,2,1,1,1,1,0),(3,1,2,1,4,2,1,1,0,1),(5,2,1,1,3,1,2,1,1,0)]
        state={};rows=0
        for line in r.stdout.splitlines():
            if not line.startswith('PIX '):continue
            g,epoch,*actual=map(int,line.split()[1:]);key=(g,epoch)
            count,active=state.get(key,(0,0))
            ha,hf,hw,hb,va,vf,vw,vb,hp,vp=configs[g];ht=ha+hf+hw+hb;vt=va+vf+vw+vb
            x=count%ht;y=(count//ht)%vt;de=int(x<ha and y<va)
            expected=[x,y,hp if ha+hf<=x<ha+hf+hw else 1-hp,vp if va+vf<=y<va+vf+vw else 1-vp,de,int(de and x==0 and y==0),int(de and x==ha-1),int(de and x==ha-1 and y==va-1),int(x==ht-1 and y==vt-1),count//(ht*vt),active,count]
            if actual!=expected:raise AssertionError(f'{key} sample {count}: actual={actual} expected={expected}')
            state[key]=(count+1,active+de);rows+=1
        if set(state)!={(0,1),(1,1),(1,2),(2,1),(2,3)}:raise AssertionError(f'missing epochs {state}')
        if min(v[0] for v in state.values())<100:raise AssertionError('insufficient samples')
        if 'PASS multi output timing' not in r.stdout:raise AssertionError('no completion')
        report.update(status='PASS',raster_ticks=rows,epochs={f'{g}:{e}':{'ticks':n,'active_pixels':a} for (g,e),(n,a) in state.items()},scope='digital timing/counters only; compositor/CRC/board integration open')
        print(f'PASS three independent timing outputs: {rows} exact raster/sync/counter ticks; stop/restart,abort,invalid config,recovery')
    except Exception as exc:report['reason']=str(exc);raise
    finally:(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':main()
