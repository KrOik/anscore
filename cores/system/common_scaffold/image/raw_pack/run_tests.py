"""Independent RAW payload golden bytes plus pixel -> pack -> unpack roundtrip."""
import hashlib,json,os,pathlib,random,shutil,subprocess,tempfile
HERE=pathlib.Path(__file__).resolve().parent
UNPACK=HERE.parent/'raw_unpack/img_csi2_raw_unpack.v'
def golden_bytes(pixels,bits):
    if bits==10:
        a,b,c,d=pixels
        return [a//4,b//4,c//4,d//4,(d%4)*64+(c%4)*16+(b%4)*4+a%4]
    a,b=pixels
    return [a//16,b//16,(b%16)*16+a%16]
def execute(cmd,cwd):
    env=os.environ.copy();oss=HERE.parents[3]/'tools/oss-cad-suite/oss-cad-suite'
    if oss.exists():env['PATH']=os.pathsep.join([str(oss/'bin'),str(oss/'lib'),env.get('PATH','')])
    cmd[0]=shutil.which(cmd[0],path=env['PATH']) or cmd[0]
    p=subprocess.run(cmd,cwd=cwd,env=env,text=True,capture_output=True,timeout=120)
    if p.returncode:raise RuntimeError(str(cmd)+'\n'+p.stdout+p.stderr)
    return p.stdout+p.stderr
def profile(bits):
    rng=random.Random(5120+bits);group=4 if bits==10 else 2
    inputs=[];pixels=[];packed=[];errors=[]
    def good(p,sof=False,eol=False):
        inputs.extend((v,int(sof and i==0),int(eol and i==group-1)) for i,v in enumerate(p))
        pixels.extend(v | (int(sof and i==0)<<(bits+1)) | (int(eol and i==group-1)<<bits) for i,v in enumerate(p))
        b=golden_bytes(p,bits)
        packed.extend(v | (int(sof and i==0)<<9) | (int(eol and i==len(b)-1)<<8) for i,v in enumerate(b))
    assert golden_bytes([0,1,2,1023],10)==[0,0,0,255,228]
    assert golden_bytes([0xabc,0x123],12)==[0xab,0x12,0x3c]
    good([0,1,2,1023] if bits==10 else [0xabc,0x123],True,True)
    for frame in range(20):
        for row in range(rng.randrange(1,9)):
            groups=rng.randrange(1,14)
            for col in range(groups):
                p=[rng.randrange(1<<bits) for _ in range(group)]
                if col==0:p[0]=0
                if col==groups-1:p[-1]=(1<<bits)-1
                good(p,sof=row==0 and col==0,eol=col==groups-1)
    for length in range(1,group):
        inputs.extend((rng.randrange(1<<bits),int(i==0),int(i==length-1)) for i in range(length));errors.append(1)
        good([rng.randrange(1<<bits) for _ in range(group)],True,True)
    for length in range(1,group):
        inputs.extend((17,int(i==0),0) for i in range(length));errors.append(2)
        good([rng.randrange(1<<bits) for _ in range(group)],True,True)
    inputs.append((0,1,1));errors.append(1)
    good([0]*group,True,True)
    with tempfile.TemporaryDirectory(prefix='raw_pack_') as tmp:
        p=pathlib.Path(tmp)
        (p/'input.txt').write_text(''.join(f'{v} {s} {e}\n' for v,s,e in inputs))
        for name,values in [('bytes',packed),('pixels',pixels),('errors',errors)]:
            (p/f'{name}.mem').write_text(''.join(f'{v:x}\n' for v in values))
        (p/'counts.vh').write_text(f'localparam BYTE_COUNT={len(packed)},PIXEL_COUNT={len(pixels)},ERROR_COUNT={len(errors)};\n')
        execute(['iverilog','-g2012','-I',str(p),'-s','tb',f'-Ptb.RAW_BITS={bits}','-o',str(p/'sim.vvp'),str(HERE/'img_csi2_raw_pack.v'),str(UNPACK),str(HERE/'tb_img_csi2_raw_pack.sv')],p)
        output=execute(['vvp',str(p/'sim.vvp')],p)
        assert f'PACK RAW{bits} PASS bytes={len(packed)} pixels={len(pixels)} errors={len(errors)}' in output,output
    print(output,end='')
    return {'bits':bits,'pixels':len(pixels),'packed_bytes':len(packed),'error_events':len(errors),'status':'PASS'}
def main():
    profiles=[profile(10),profile(12)]
    with tempfile.TemporaryDirectory(prefix='raw_pack_invalid_') as tmp:
        p=pathlib.Path(tmp)
        execute(['iverilog','-g2012','-s','tb_invalid','-o',str(p/'sim.vvp'),str(HERE/'img_csi2_raw_pack.v'),str(HERE/'tb_raw_pack_invalid.sv')],p)
        output=execute(['vvp',str(p/'sim.vvp')],p)
        assert 'PACK invalid parameter PASS' in output,output
        print(output,end='')
    result={'status':'PASS','profiles':profiles,'rtl_sha256':hashlib.sha256((HERE/'img_csi2_raw_pack.v').read_bytes()).hexdigest(),'unpack_dependency_sha256':hashlib.sha256(UNPACK.read_bytes()).hexdigest(),'board_tested':False}
    (HERE/'test_result.json').write_text(json.dumps(result,indent=2)+'\n')
if __name__=='__main__':main()
