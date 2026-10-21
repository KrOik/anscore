"""Independent exhaustive block SAD / deterministic tie / validity oracle."""
import collections,hashlib,json,pathlib,random,sys,tempfile
HERE=pathlib.Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import execute
def oracle(current,reference,w,h,bw,bh,r,maxsad,mingap):
    result=[]
    for y in range(0,h,bh):
        for x in range(0,w,bw):
            aw=min(bw,w-x);ah=min(bh,h-y);candidates=[]
            for dy in range(-r,r+1):
                for dx in range(-r,r+1):
                    if 0<=x+dx<=w-aw and 0<=y+dy<=h-ah:
                        sad=sum(abs(current[(y+yy)*w+x+xx]-reference[(y+dy+yy)*w+x+dx+xx]) for yy in range(ah) for xx in range(aw))
                        candidates.append((sad,abs(dx)+abs(dy),dy,dx))
            ordered=sorted(candidates);best=ordered[0];sad,_,dy,dx=best
            second=ordered[1][0] if len(ordered)>1 else 0xffffffff
            gap=second-sad if len(ordered)>1 else 0xffffffff
            reason=int(sad>maxsad)|(int(gap<mingap)<<1)
            result.append((x,y,aw,ah,dx,dy,sad,second,gap,reason))
    return result
def profile(w,h,bits,bw,bh,r):
    rng=random.Random(w*100+h*10+bits+r);n=w*h;mx=(1<<bits)-1;cases=[]
    def add(a,b,maxsad=0xffffffff,mingap=0):cases.append((a,b,maxsad,mingap))
    add([0]*n,[0]*n);add([0]*n,[0]*n,mingap=1)
    add([mx]*n,[0]*n);add([mx]*n,[0]*n,maxsad=0,mingap=0xffffffff)
    texture=[rng.randrange(mx+1) for _ in range(n)]
    add(texture,texture)
    for dx,dy in [(-1,0),(1,0),(0,-1),(0,1),(1,-1),(-1,1)]:
        shifted=[]
        for y in range(h):
            for x in range(w):
                xx,yy=x+dx,y+dy
                shifted.append(texture[yy*w+xx] if 0<=xx<w and 0<=yy<h else rng.randrange(mx+1))
        add(shifted,texture)
    for _ in range(4):add([rng.randrange(mx+1) for _ in range(n)],[rng.randrange(mx+1) for _ in range(n)],rng.randrange(max(1,bw*bh*mx+1)),rng.randrange(20))
    # Exact max-SAD and exact uniqueness-gap boundaries must be accepted.
    initial=oracle(texture,texture,w,h,bw,bh,r,0xffffffff,0)
    add(texture,texture,maxsad=initial[0][6],mingap=initial[0][8])
    if bw==1 and bh==1 and w>=3 and h>=3 and r>=1:
        cx,cy=w//2,h//2
        for offsets in [[(0,-1),(0,1),(-1,0),(1,0)],[(-1,0),(1,0)]]:
            reference=[mx]*n
            for dx,dy in offsets:reference[(cy+dy)*w+cx+dx]=0
            add([0]*n,reference)
    expected=[oracle(a,b,w,h,bw,bh,r,ms,mg) for a,b,ms,mg in cases]
    known_vectors=0
    for frame,(dx,dy) in enumerate([(-1,0),(1,0),(0,-1),(0,1),(1,-1),(-1,1)],start=5):
        if abs(dx)>r or abs(dy)>r:continue
        for x,y,aw,ah,gotdx,gotdy,sad,*_ in expected[frame]:
            if aw==bw and ah==bh and aw*ah>=4 and 0<=x+dx<=w-aw and 0<=y+dy<=h-ah:
                assert (gotdx,gotdy,sad)==(dx,dy,0),'known texture translation'
                known_vectors+=1
    if len(cases)==18:
        center=(h//2)*w+w//2
        assert expected[-2][center][4:6]==(0,-1),'signed dy tie ordering'
        assert expected[-1][center][4:6]==(-1,0),'signed dx tie ordering'
    with tempfile.TemporaryDirectory(prefix='block_motion_') as tmp:
        p=pathlib.Path(tmp)
        (p/'input.mem').write_text(''.join(f'{(a[i]<<bits)|b[i]:x}\n' for a,b,ms,mg in cases for i in range(n)))
        (p/'thresholds.mem').write_text(''.join(f'{(ms<<32)|mg:x}\n' for a,b,ms,mg in cases))
        (p/'geometry.vh').write_text(f'localparam WIDTH={w},HEIGHT={h},BITS={bits},BLOCK_W={bw},BLOCK_H={bh},SEARCH_RANGE={r},CASES={len(cases)},BLOCKS={len(expected[0])};\n')
        execute(['iverilog','-g2012','-I',p,'-s','tb','-o',p/'sim.vvp',HERE/'img_block_motion.v',HERE/'tb_img_block_motion.sv'],p,p/'compile.log')
        output=execute(['vvp',p/'sim.vvp'],p,p/'simulation.log',timeout=120)
        assert f'MOTION PASS {w}x{h}' in output,output
    actual=collections.defaultdict(list)
    for line in output.splitlines():
        fields=line.split()
        if fields and fields[0]=='B':actual[int(fields[1])].append(tuple(map(int,fields[3:])))
    for frame,want in enumerate(expected):assert actual[frame]==want,(w,h,bits,r,frame,actual[frame],want)
    assert actual[len(cases)+1]==oracle([0]*n,[0]*n,w,h,bw,bh,r,0xffffffff,0),'bad-frame recovery'
    print(f'MOTION PASS {w}x{h} BITS={bits} BLOCK={bw}x{bh} R={r} frames={len(cases)} vectors={sum(map(len,expected))}')
    return {'width':w,'height':h,'bits':bits,'block_w':bw,'block_h':bh,'search_range':r,'frames':len(cases),'vectors':sum(map(len,expected)),'known_translation_vectors':known_vectors,'status':'PASS'}
def main():
    profiles=[profile(*p) for p in [(1,1,8,8,8,2),(9,7,8,4,3,2),(7,1,10,3,4,2),(1,7,12,4,3,2),(8,8,12,8,8,0),(5,4,9,2,2,1),(5,5,11,1,1,1),(64,64,12,64,64,0)]]
    (HERE/'test_result.json').write_text(json.dumps({'status':'PASS','profiles':profiles,'rtl_sha256':hashlib.sha256((HERE/'img_block_motion.v').read_bytes()).hexdigest(),'board_tested':False},indent=2)+'\n')
if __name__=='__main__':main()
