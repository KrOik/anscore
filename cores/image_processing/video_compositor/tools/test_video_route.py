"""Four sources, shared destinations, full video metadata and runtime rerouting."""
from datetime import datetime,timezone
import hashlib,json,subprocess
from pathlib import Path
ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir());P=ROOT/'cores/image_processing/video_compositor'
def main():
    out=ROOT/'artifacts/video_compositor_25k'/datetime.now(timezone.utc).strftime('video_route_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    sources=[P/'rtl/video_route4.v',P/'rtl/frame_atomic_config.v',P/'tb/tb_video_route4.v',ROOT/'cores/system/stream_bus_library/rtl/sys_atomic_config.v',ROOT/'cores/system/stream_bus_library/rtl/sys_frame_switch4.v']
    report=dict(status='FAIL',physical_measurement=False,sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources+[Path(__file__).resolve()]})
    print('Evidence='+str(out),flush=True)
    try:
        exe=out/'test.vvp'
        for label,cmd in [('compile',['iverilog','-g2012','-s','tb_video_route4','-o',str(exe)]+list(map(str,sources))),('run',['vvp',str(exe)])]:
            r=subprocess.run(cmd,cwd=ROOT,capture_output=True,text=True,timeout=60);(out/(label+'.log')).write_text(r.stdout+r.stderr)
            if r.returncode:raise RuntimeError(r.stdout+r.stderr)
        seen=[0]*4;owners={};rows=0
        for line in r.stdout.splitlines():
            if not line.startswith('PIX '):continue
            dest,pixel,frame,user,error,sof,eol,last,index=map(int,line.split()[1:])
            g=pixel>>20;n=seen[g];f=n//(9+g);expected_dest=g%2 if f==0 else (g+1)%4
            actual=(dest,pixel,frame,user,error,sof,eol,last,index)
            expected=(expected_dest,(g<<20)|n,0x80000000+g*256+f,n,g<<4,int(n%(9+g)==0),int(n%3==2),int(n%(9+g)==8+g),rows)
            if actual!=expected:raise AssertionError(f'{actual} != {expected}')
            if dest in owners and owners[dest]!=(g,f):raise AssertionError('frame interleaving')
            owners[dest]=(g,f)
            if last:del owners[dest]
            seen[g]+=1;rows+=1
        if seen!=[72,80,88,96] or owners or 'PASS video route4' not in r.stdout:raise AssertionError('incomplete routing')
        report.update(status='PASS',pixels=rows,frames=32,scope='elastic frame-safe external video router; scanout buffering/CSR/board pending')
        print('PASS route4:336 exact pixels/metadata,32 frames,contention,random gaps/stalls,midframe route commits')
    except Exception as exc:report['reason']=str(exc);raise
    finally:(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':main()
