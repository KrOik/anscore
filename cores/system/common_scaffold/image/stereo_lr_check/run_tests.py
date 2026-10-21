"""Independent rectified correspondence oracle and bounded RTL transactions."""
import collections,hashlib,json,pathlib,random,sys,tempfile
HERE=pathlib.Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import execute
def oracle(left,right,li,ri,w,h,threshold):
    result=[]
    for row in range(h):
        for x in range(w):
            i=row*w+x;d=left[i];rx=x-d
            if li[i]:reason=1
            elif not 0<=rx<w:reason=2
            elif ri[row*w+rx]:reason=3
            elif abs(d-right[row*w+rx])>threshold:reason=4
            else:reason=0
            result.append((d,reason))
    return result
def profile(w,h,bits):
    rng=random.Random(w*100+h+bits);n=w*h;maximum=(1<<bits)-1
    cases=[]
    def add(left,right,li=None,ri=None,t=0):
        cases.append((left,right,li or [0]*n,ri or [0]*n,t))
    add([0]*n,[0]*n)
    add([maximum]*n,[maximum]*n)
    add([min(i%w,maximum) for i in range(n)],[0]*n,t=0) # all map to row start
    add([0]*n,[maximum]*n,t=maximum) # equality to threshold passes
    add([0]*n,[maximum]*n,t=max(0,maximum-1))
    add([0]*n,[0]*n,li=[1]*n,ri=[1]*n)
    add([0]*n,[0]*n,ri=[1]*n)
    for t in [0,1,min(3,maximum),maximum]:
        for _ in range(3):
            left=[rng.randrange(min(w+2,maximum+1)) for _ in range(n)]
            right=[rng.randrange(min(w+2,maximum+1)) for _ in range(n)]
            li=[int(rng.random()<.12) for _ in range(n)];ri=[int(rng.random()<.2) for _ in range(n)]
            add(left,right,li,ri,t)
    expected=[oracle(*case[:4],w,h,case[4]) for case in cases]
    with tempfile.TemporaryDirectory(prefix='stereo_lr_') as tmp:
        p=pathlib.Path(tmp)
        values=[]
        for left,right,li,ri,t in cases:
            values += [(li[i]<<(2*bits+1))|(ri[i]<<(2*bits))|(left[i]<<bits)|right[i] for i in range(n)]
        (p/'input.mem').write_text(''.join(f'{v:x}\n' for v in values))
        (p/'thresholds.mem').write_text(''.join(f'{case[4]:x}\n' for case in cases))
        (p/'geometry.vh').write_text(f'localparam WIDTH={w},HEIGHT={h},DISP_BITS={bits},CASES={len(cases)};\n')
        execute(['iverilog','-g2012','-I',p,'-s','tb','-o',p/'sim.vvp',HERE/'img_stereo_lr_check.v',HERE/'tb_img_stereo_lr_check.sv'],p,p/'compile.log')
        output=execute(['vvp',p/'sim.vvp'],p,p/'simulation.log')
        assert f'LR PASS {w}x{h} D={bits}' in output,output
    actual=collections.defaultdict(list)
    for line in output.splitlines():
        fields=line.split()
        if fields and fields[0]=='P':actual[int(fields[1])].append(tuple(map(int,fields[3:])))
    for f,want in enumerate(expected):assert actual[f]==want,(w,h,bits,f,actual[f],want)
    assert actual[len(cases)+1]==[(0,0)]*n,'bad-frame recovery'
    assert not actual[len(cases)+2],'missing SOF produced output'
    assert actual[len(cases)+3]==[(0,0)]*n,'missing-SOF recovery'
    coverage=collections.Counter(reason for frame in expected for d,reason in frame)
    print(f'LR PASS {w}x{h} D={bits} frames={len(cases)} samples={n*len(cases)} reasons={dict(coverage)}')
    return {'width':w,'height':h,'disp_bits':bits,'frames':len(cases),'samples':n*len(cases),'reason_counts':dict(coverage),'status':'PASS'}
def main():
    profiles=[profile(w,h,bits) for w,h,bits in [(1,1,1),(1,9,8),(11,1,8),(9,7,4),(17,5,12),(5,3,16)]]
    with tempfile.TemporaryDirectory(prefix='lr_param_') as tmp:
        p=pathlib.Path(tmp)
        for width,valid in [(256,True),(257,False)]:
            (p/'param.sv').write_text(f'module tb_param; img_stereo_lr_check #(.WIDTH({width}),.HEIGHT(256),.DISP_BITS(1)) dut(); initial begin #1;$display("PARAM_ACCEPT");$finish;end endmodule\n')
            execute(['iverilog','-g2012','-s','tb_param','-o',p/'param.vvp',HERE/'img_stereo_lr_check.v',p/'param.sv'],p,p/'compile.log')
            try:
                output=execute(['vvp',p/'param.vvp'],p,p/'simulation.log')
            except RuntimeError as exc:
                assert not valid and 'invalid geometry/disparity parameters' in str(exc),str(exc)
            else:assert valid and 'PARAM_ACCEPT' in output
    (HERE/'test_result.json').write_text(json.dumps({'status':'PASS','profiles':profiles,'pixel_capacity_boundary':{'65536':'ELABORATION_PASS','65792':'EXPLICIT_REJECT_PASS'},'rtl_sha256':hashlib.sha256((HERE/'img_stereo_lr_check.v').read_bytes()).hexdigest(),'board_tested':False},indent=2)+'\n')
if __name__=='__main__':main()
