"""Independent plane/stride address golden and transactional byte memory model."""
import hashlib,json,os,pathlib,random,shutil,subprocess,tempfile
HERE=pathlib.Path(__file__).resolve().parent
def execute(cmd,cwd):
    env=os.environ.copy();oss=HERE.parents[3]/'tools/oss-cad-suite/oss-cad-suite'
    if oss.exists():env['PATH']=os.pathsep.join([str(oss/'bin'),str(oss/'lib'),env.get('PATH','')])
    cmd[0]=shutil.which(cmd[0],path=env['PATH']) or cmd[0]
    r=subprocess.run(cmd,cwd=cwd,env=env,capture_output=True,text=True,timeout=120)
    if r.returncode:raise RuntimeError(r.stdout+r.stderr)
    return r.stdout+r.stderr
def profile(w,h,reverse=False,tight=False):
    rng=random.Random(735+w*10+h);cw=(w+1)//2;ch=(h+1)//2
    ys=w if tight else w+7;uvs=2*cw if tight else 2*cw+5;yb,uvb=(4096,17) if reverse else (17,4096)
    y=[[rng.randrange(256) for _ in range(w)] for _ in range(h)]
    u=[[rng.randrange(256) for _ in range(cw)] for _ in range(ch)]
    v=[[rng.randrange(256) for _ in range(cw)] for _ in range(ch)]
    words=[];transfers=[]
    for row in range(h):
        chromaline=row%2==1 or row==h-1
        for col in range(cw):
            a=y[row][col*2];b=y[row][col*2+1] if col*2+1<w else 0
            words.append((int(row==0 and col==0)<<18) | (int(col==cw-1 and not chromaline)<<17) | a*256+b)
            transfers.append([(yb+row*ys+col*2,a)]+([(yb+row*ys+col*2+1,b)] if col*2+1<w else []))
            if chromaline:
                words.append((int(col==cw-1)<<17)|(1<<16)|u[row//2][col]*256+v[row//2][col])
                transfers.append([(uvb+(row//2)*uvs+col*2,u[row//2][col]),(uvb+(row//2)*uvs+col*2+1,v[row//2][col])])
    requests=[];memory=[0xa5]*8192
    recon=[]
    for row in range(h):
        for col in range(w):
            cy=min(ch-1,(row+1)//2);cx=min(cw-1,(col+1)//2)
            recon.append((int(row==0 and col==0)<<25)|(int(col==w-1)<<24)|y[row][col]*65536+u[cy][cx]*256+v[cy][cx])
    for nv21 in [False,True]:
        mode_transfers=[]
        for word,pairs in zip(words,transfers):
            if nv21 and word&(1<<16):pairs=[(pairs[0][0],pairs[1][1]),(pairs[1][0],pairs[0][1])]
            mode_transfers.extend(pairs)
        for addr,data in mode_transfers:
            requests.append((1<<40)|(addr<<8)|data);memory[addr]=data
        for addr,data in mode_transfers:requests.append(addr<<8)
    with tempfile.TemporaryDirectory(prefix='nv12_layout_') as tmp:
        p=pathlib.Path(tmp)
        for name,vals in [('words',words),('requests',requests),('memory',memory),('recon',recon)]:
            (p/f'{name}.mem').write_text(''.join(f'{v:x}\n' for v in vals))
        (p/'geometry.vh').write_text(f'localparam WIDTH={w},HEIGHT={h},YBASE={yb},UVBASE={uvb},YS={ys},UVS={uvs},WORDS={len(words)},REQUESTS={len(requests)};\n')
        execute(['iverilog','-g2012','-I',str(p),'-s','tb','-o',str(p/'sim.vvp'),str(HERE/'img_nv12_layout.v'),str(HERE.parent/'chroma_reconstruct/upsample420/chroma_420_to_444.sv'),str(HERE/'tb_img_nv12_layout.sv')],p)
        out=execute(['vvp',str(p/'sim.vvp')],p)
        assert f'NV12 PASS {w}x{h}' in out,out
        print(out,end='')
    return {'width':w,'height':h,'reverse_planes':reverse,'tight_strides':tight,'requests':len(requests),'macros':2*len(words),'status':'PASS'}
def main():
    results=[profile(*p) for p in [(1,1,False,True),(2,2,False,False),(3,5,True,False),(8,6,False,True),(9,4,True,False)]]
    recon=HERE.parent/'chroma_reconstruct/upsample420/chroma_420_to_444.sv'
    (HERE/'test_result.json').write_text(json.dumps({'status':'PASS','profiles':results,'rtl_sha256':hashlib.sha256((HERE/'img_nv12_layout.v').read_bytes()).hexdigest(),'reconstruction_dependency_sha256':hashlib.sha256(recon.read_bytes()).hexdigest(),'successful_memory_requests':sum(r['requests'] for r in results),'reconstructed444_pixels':sum(2*r['width']*r['height'] for r in results),'board_tested':False},indent=2)+'\n')
if __name__=='__main__':main()
