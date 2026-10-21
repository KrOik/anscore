"""Coordinate oracle independent of RTL counters and original-image roundtrip."""
import hashlib,json,os,pathlib,random,shutil,subprocess,tempfile
HERE=pathlib.Path(__file__).resolve().parent
def execute(cmd,cwd):
    env=os.environ.copy();oss=HERE.parents[3]/'tools/oss-cad-suite/oss-cad-suite'
    if oss.exists():env['PATH']=os.pathsep.join([str(oss/'bin'),str(oss/'lib'),env.get('PATH','')])
    cmd[0]=shutil.which(cmd[0],path=env['PATH']) or cmd[0]
    r=subprocess.run(cmd,cwd=cwd,env=env,capture_output=True,text=True,timeout=120)
    if r.returncode:raise RuntimeError(r.stdout+r.stderr)
    return r.stdout+r.stderr
def profile(bits,w,h):
    rng=random.Random(bits*10000+w*100+h);bx=(w+7)//8;by=(h+7)//8
    sources=[];blocks=[];rasters=[];forced=[]
    for frame in range(3):
        image=[[rng.randrange(1<<bits) for _ in range(w)] for _ in range(h)]
        image[0][0]=0;image[-1][-1]=(1<<bits)-1
        for y in range(h):
            for x in range(w):
                sof=int(x==0 and y==0);eol=int(x==w-1);last=int(x==w-1 and y==h-1)
                if frame<2:sources.append((sof<<(bits+1)) | (eol<<bits) | image[y][x])
                rasters.append((sof<<(bits+2)) | (eol<<(bits+1)) | (last<<bits) | image[y][x])
        for blockrow in range(by):
            for blockcol in range(bx):
                for offset in range(64):
                    yy,xx=divmod(offset,8);y=min(h-1,blockrow*8+yy);x=min(w-1,blockcol*8+xx)
                    first=int(offset==0);last=int(offset==63);sof=int(blockrow==0 and blockcol==0 and first)
                    final=int(blockrow==by-1 and blockcol==bx-1 and last);eol=int(xx==7)
                    pixel=image[y][x]
                    if frame<2:blocks.append((sof<<(bits+4))|(eol<<(bits+3))|(first<<(bits+2))|(last<<(bits+1))|(final<<bits)|pixel)
                    else:
                        # Independent inverse test: padding carries unrelated noise,
                        # so copying it into the real frame cannot accidentally pass.
                        if blockrow*8+yy>=h or blockcol*8+xx>=w:pixel=rng.randrange(1<<bits)
                        forced.append((sof<<(bits+3))|(eol<<(bits+2))|(first<<(bits+1))|(last<<bits)|pixel)
    with tempfile.TemporaryDirectory(prefix='raster_blocks_') as tmp:
        p=pathlib.Path(tmp)
        for name,values in [('input',sources),('blocks',blocks),('raster',rasters),('force',forced)]:
            (p/f'{name}.mem').write_text(''.join(f'{v:x}\n' for v in values))
        (p/'geometry.vh').write_text(f'localparam BITS={bits},WIDTH={w},HEIGHT={h},REAL={w*h},PADDED={bx*by*64};\n')
        execute(['iverilog','-g2012','-I',str(p),'-s','tb','-o',str(p/'sim.vvp'),str(HERE/'img_raster_blocks.v'),str(HERE/'tb_img_raster_blocks.sv')],p)
        output=execute(['vvp',str(p/'sim.vvp')],p)
        assert f'RASTER PASS BITS={bits} {w}x{h}' in output,output
        print(output,end='')
    return {'bits':bits,'width':w,'height':h,'forward_samples':len(blocks),'inverse_samples':len(rasters),'status':'PASS'}
def main():
    profiles=[profile(bits,w,h) for bits in [8,10,12] for w,h in [(1,1),(8,8),(9,13),(17,3)]]
    (HERE/'test_result.json').write_text(json.dumps({'status':'PASS','profiles':profiles,'rtl_sha256':hashlib.sha256((HERE/'img_raster_blocks.v').read_bytes()).hexdigest(),'board_tested':False},indent=2)+'\n')
if __name__=='__main__':main()
