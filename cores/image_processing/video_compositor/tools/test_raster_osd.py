"""Independent complete raster/OSD/config/CRC oracle for three live scanouts."""
from datetime import datetime,timezone
import hashlib,json,subprocess,zlib
from pathlib import Path
from test_dual_osd import blend
ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir());P=ROOT/'cores/image_processing/video_compositor'
def main():
    out=ROOT/'artifacts/video_compositor_25k'/datetime.now(timezone.utc).strftime('raster_osd_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    sources=[P/'rtl/raster_osd_output.v',P/'rtl/dual_osd_stream.v',P/'rtl/video_frame_crc.v',P/'tb/tb_raster_osd.v',ROOT/'cores/system/common_scaffold/image/multiframe/img_mf_rgb_blend_pipe.v',ROOT/'cores/system/common_scaffold/image/video_scanout/video_timing_generator.sv',ROOT/'cores/system/stream_bus_library/rtl/sys_atomic_config.v']
    report=dict(status='FAIL',physical_measurement=False,sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources+[Path(__file__).resolve(),P/'tools/test_dual_osd.py']})
    print('Evidence='+str(out),flush=True)
    try:
        exe=out/'test.vvp'
        for label,cmd in [('compile',['iverilog','-g2012','-s','tb_raster_osd','-o',str(exe)]+list(map(str,sources))),('run',['vvp',str(exe)])]:
            r=subprocess.run(cmd,cwd=ROOT,capture_output=True,text=True,timeout=60);(out/(label+'.log')).write_text(r.stdout+r.stderr)
            if r.returncode:raise RuntimeError(r.stdout+r.stderr)
        inputs=[[],[],[]];outputs=[[],[],[]];crcs=[[],[],[]]
        for line in r.stdout.splitlines():
            if line.startswith(('IN ','OUT ','CRC ')):
                label,g,*v=line.split();{'IN':inputs,'OUT':outputs,'CRC':crcs}[label][int(g)].append(tuple(map(int,v)))
        count=0;frames=0
        for g in range(3):
            if len(inputs[g])!=len(outputs[g]) or len(outputs[g])<400:raise AssertionError('lost ticks')
            ha=4+g;ht=ha+4;vt=6;raw=bytearray();golden_crc=[]
            for n,(source,actual) in enumerate(zip(inputs[g],outputs[g])):
                cycle,pixel,de,hs,vs,sof,eol,last,frame,version,error=actual
                x=n%ht;y=n//ht%vt;f=n//(ht*vt);v=2 if g==0 and f>=3 else 1
                active=int(x<ha and y<3)
                base=(0xf0a050 if v==2 else 0x123456+g*0x10101)^((x<<16)|(y<<8)|(f&255))
                expected_pixel=blend(blend(base,0x654321,128),0xabcdef,64) if active else 0
                expected=(source[0]+6,expected_pixel,active,int(ha+1<=x<ha+2),int(not(4<=y<5)),int(active and x==0 and y==0),int(active and x==ha-1),int(active and x==ha-1 and y==2),f,v,0)
                if actual!=expected:raise AssertionError(f'lane{g} tick{n}: {actual} != {expected}')
                if active:raw.extend(expected_pixel.to_bytes(3,'little'))
                if last:golden_crc.append((f,zlib.crc32(raw),ha*3,0,v));raw.clear()
                count+=1
            if crcs[g]!=golden_crc:raise AssertionError(f'lane{g} frame CRC mismatch')
            if raw:raise AssertionError('partial frame at stop')
            frames+=len(golden_crc)
        if 'PASS raster OSD integration' not in r.stdout:raise AssertionError('missing completion')
        report.update(status='PASS',raster_pixels=count,frames=frames,pipeline_latency_clocks=6,scope='digital scanout integration; PHY/CSR/25K build/physical gates open')
        print(f'PASS {count} exact raster pixels, {frames} zlib frames,6clock sync alignment,midframe atomic config switch,independent stops')
    except Exception as exc:report['reason']=str(exc);raise
    finally:(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':main()
