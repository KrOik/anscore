"""Three independently stalled real OSD pipelines; exact pixel and zlib CRC oracle."""
from datetime import datetime,timezone
import hashlib,json,random,subprocess,zlib
from pathlib import Path
from test_dual_osd import blend
ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir());P=ROOT/'cores/image_processing/video_compositor'
def main():
    out=ROOT/'artifacts/video_compositor_25k'/datetime.now(timezone.utc).strftime('parallel_crc_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    sources=[P/'rtl/dual_osd_stream.v',P/'rtl/video_frame_crc.v',P/'tb/tb_parallel_osd_crc.v',ROOT/'cores/system/common_scaffold/image/multiframe/img_mf_rgb_blend_pipe.v',P/'tb/tb_video_crc_errors.v']
    report=dict(status='FAIL',physical_measurement=False,sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources+[Path(__file__).resolve(),P/'tools/test_dual_osd.py']})
    print('Evidence='+str(out),flush=True)
    try:
        vectors=[];expected=[[],[],[]];crcs=[[],[],[]];rng=random.Random(250800)
        for g in range(3):
            raw=bytearray();frame_error=0
            for n in range(256):
                base,a,b=[rng.randrange(1<<24) for _ in range(3)]
                key0=a if n%3==0 else 0;key1=b if n%5==0 else 0
                alpha0=[0,1,128,255,256,257][(n+g)%6];alpha1=[256,64,0,511][(n//4+g)%4]
                en=(n//32+g)%4;ke=(n//16+g)%4
                error=int(bool((en&1 and alpha0>256)or(en&2 and alpha1>256)))
                pixel=base
                if not error:
                    if en&1 and not(ke&1 and a==key0):pixel=blend(pixel,a,alpha0)
                    if en&2 and not(ke&2 and b==key1):pixel=blend(pixel,b,alpha1)
                else:pixel=0
                sof=int(n%32==0);eol=int(n%8==7);last=int(n%32==31);frame=0x80000000+g*256+n//32
                vectors.append(base|(a<<24)|(b<<48)|(key0<<72)|(key1<<96)|(alpha0<<120)|(alpha1<<129)|(en<<138)|(ke<<140)|(sof<<142)|(eol<<143)|(last<<144)|(n<<145)|(frame<<161))
                expected[g].append((n,pixel,sof,eol,last,n,frame,error))
                raw.extend(pixel.to_bytes(3,'little'));frame_error|=2 if error else 0
                if last:
                    crcs[g].append((frame,zlib.crc32(raw),32,frame_error));raw.clear();frame_error=0
        fixture=out/'vectors.mem';fixture.write_text(''.join(f'{v:049x}\n' for v in vectors))
        exe=out/'test.vvp'
        for label,cmd in [('compile',['iverilog','-g2012','-s','tb_parallel_osd_crc','-o',str(exe)]+list(map(str,sources))),('run',['vvp',str(exe),'+fixture='+str(fixture)])]:
            r=subprocess.run(cmd,cwd=ROOT,capture_output=True,text=True,timeout=60);(out/(label+'.log')).write_text(r.stdout+r.stderr)
            if r.returncode:raise RuntimeError(r.stdout+r.stderr)
        actual=[[],[],[]];observed=[[],[],[]]
        for line in r.stdout.splitlines():
            if line.startswith(('PIX ','CRC ')):
                label,g,*values=line.split();(actual if label=='PIX' else observed)[int(g)].append(tuple(map(int,values)))
        if actual!=expected:raise AssertionError('pixel/metadata mismatch')
        if observed!=crcs:raise AssertionError(f'CRC mismatch: {observed} != {crcs}')
        if 'PASS parallel OSD CRC' not in r.stdout:raise AssertionError('missing completion')
        for label,cmd in [('errors_compile',['iverilog','-g2012','-s','tb_video_crc_errors','-o',str(exe)]+list(map(str,sources))),('errors_run',['vvp',str(exe)])]:
            r=subprocess.run(cmd,cwd=ROOT,capture_output=True,text=True,timeout=60);(out/(label+'.log')).write_text(r.stdout+r.stderr)
            if r.returncode:raise RuntimeError(r.stdout+r.stderr)
        observed_errors=[tuple(map(int,line.split()[1:])) for line in r.stdout.splitlines() if line.startswith('RESULT ')]
        a=bytes([1,2,3]);b=bytes([4,5,6])
        expected_errors=[(1,zlib.crc32(a),1,1),(2,zlib.crc32(a+b),2,4),(3,zlib.crc32(a+b),2,1),(5,zlib.crc32(b),1,1),(6,zlib.crc32(a),1,2),(7,zlib.crc32(a+b),2,0),(9,zlib.crc32(b),1,0)]
        if observed_errors!=expected_errors:raise AssertionError(f'error CRC mismatch {observed_errors} != {expected_errors}')
        if 'PASS CRC errors' not in r.stdout:raise AssertionError('missing error completion')
        report.update(status='PASS',pixels=768,frames=24,error_recovery_results=7,scope='three parallel elastic compositors and passive CRC; raster/config/board integration pending')
        print('PASS 768 exact pixels/metadata,24 zlib frame CRCs,7 malformed/error/stall/reset results')
    except Exception as exc:report['reason']=str(exc);raise
    finally:(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':main()
