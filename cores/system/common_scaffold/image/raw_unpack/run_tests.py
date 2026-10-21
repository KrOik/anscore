"""CSI-2 RAW10/RAW12 pack oracle and independent source-pixel scoreboard."""
import hashlib,json,os,pathlib,random,shutil,subprocess,tempfile
HERE=pathlib.Path(__file__).resolve().parent
def pack(pixels,bits):
    low=bits-8
    return [p>>low for p in pixels]+[sum((p&((1<<low)-1))<<(i*low) for i,p in enumerate(pixels))]
def tools_env():
    env=os.environ.copy();oss=HERE.parents[3]/'tools/oss-cad-suite/oss-cad-suite'
    if oss.exists():env['PATH']=os.pathsep.join([str(oss/'bin'),str(oss/'lib'),env.get('PATH','')])
    return env
def execute(command,cwd):
    env=tools_env();command[0]=shutil.which(command[0],path=env['PATH']) or command[0]
    p=subprocess.run(command,cwd=cwd,env=env,text=True,capture_output=True,timeout=120)
    if p.returncode:raise RuntimeError(str(command)+'\n'+p.stdout+p.stderr)
    return p.stdout+p.stderr
def profile(bits):
    rng=random.Random(4859+bits);group=4 if bits==10 else 2
    inputs=[];expected=[];errors=[]
    def good(pixels,sof=False,eol=False):
        data=pack(pixels,bits)
        inputs.extend((v,int(sof and i==0),int(eol and i==len(data)-1)) for i,v in enumerate(data))
        expected.extend(p | (int(sof and i==0)<<(bits+1)) | (int(eol and i==group-1)<<bits) for i,p in enumerate(pixels))
    # Explicit canonical CSI-2 packing examples, independent of HDL expressions.
    assert pack([0,1,2,1023],10)==[0,0,0,255,228]
    assert pack([0xabc,0x123],12)==[0xab,0x12,0x3c]
    for frame in range(15):
        for row in range(rng.randrange(1,8)):
            groups=rng.randrange(1,16)
            for col in range(groups):
                pixels=[rng.randrange(1<<bits) for _ in range(group)]
                if col==0:pixels[0]=0
                if col==groups-1:pixels[-1]=(1<<bits)-1
                good(pixels,sof=row==0 and col==0,eol=col==groups-1)
    # Every possible incomplete group length ends with an explicit partial EOL.
    for length in range(1,group+1):
        inputs.extend((rng.randrange(256),int(i==0),int(i==length-1)) for i in range(length));errors.append(1)
        good([rng.randrange(1<<bits) for _ in range(group)],sof=True,eol=True)
    # A SOF on each possible partial position discards prior bytes and restarts.
    for length in range(1,group+1):
        inputs.extend((0xa5,int(i==0),0) for i in range(length));errors.append(2)
        good([rng.randrange(1<<bits) for _ in range(group)],sof=True,eol=True)
    # SOF and EOL on one byte is rejected, never interpreted as a pixel.
    inputs.append((255,1,1));errors.append(1)
    good([0]*group,sof=True,eol=True)
    with tempfile.TemporaryDirectory(prefix='raw_unpack_') as tmp:
        p=pathlib.Path(tmp)
        (p/'input.txt').write_text(''.join(f'{v} {s} {e}\n' for v,s,e in inputs))
        (p/'pixels.mem').write_text(''.join(f'{v:x}\n' for v in expected))
        (p/'errors.mem').write_text(''.join(f'{v:x}\n' for v in errors))
        (p/'counts.vh').write_text(f'localparam EXPECTED_COUNT={len(expected)}, ERROR_COUNT={len(errors)};\n')
        execute(['iverilog','-g2012','-I',str(p),'-s','tb',f'-Ptb.RAW_BITS={bits}','-o',str(p/'sim.vvp'),str(HERE/'img_csi2_raw_unpack.v'),str(HERE/'tb_img_csi2_raw_unpack.sv')],p)
        output=execute(['vvp',str(p/'sim.vvp')],p)
        assert f'RAW{bits} PASS pixels={len(expected)} errors={len(errors)}' in output,output
    print(output,end='')
    return {'bits':bits,'pixels':len(expected),'input_bytes':len(inputs),'error_events':len(errors),'status':'PASS'}
def main():
    profiles=[profile(10),profile(12)]
    with tempfile.TemporaryDirectory(prefix='raw_invalid_') as tmp:
        p=pathlib.Path(tmp)
        execute(['iverilog','-g2012','-s','tb_invalid','-o',str(p/'sim.vvp'),str(HERE/'img_csi2_raw_unpack.v'),str(HERE/'tb_raw_unpack_invalid.sv')],p)
        output=execute(['vvp',str(p/'sim.vvp')],p)
        assert 'RAW invalid parameter PASS' in output,output
        print(output,end='')
    result={'status':'PASS','profiles':profiles,'rtl_sha256':hashlib.sha256((HERE/'img_csi2_raw_unpack.v').read_bytes()).hexdigest(),'board_tested':False}
    (HERE/'test_result.json').write_text(json.dumps(result,indent=2)+'\n')
if __name__=='__main__':main()
