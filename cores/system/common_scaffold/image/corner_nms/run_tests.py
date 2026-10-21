"""Independent neighborhood oracle plus actual FAST9 -> NMS RTL chain."""
import collections,hashlib,json,pathlib,random,sys,tempfile
HERE=pathlib.Path(__file__).resolve().parent
FAST=HERE.parent/'fast9/img_fast9_frame.sv'
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import execute
CIRCLE=[(0,-3),(1,-3),(2,-2),(3,-1),(3,0),(3,1),(2,2),(1,3),
        (0,3),(-1,3),(-2,2),(-3,1),(-3,0),(-3,-1),(-2,-2),(-1,-3)]
def fast_scores(image,w,h):
    scores=[]
    for y in range(h):
        for x in range(w):
            strength=0
            if 3<=x<w-3 and 3<=y<h-3:
                center=image[y*w+x];ring=[image[(y+dy)*w+x+dx]-center for dx,dy in CIRCLE]
                for start in range(16):
                    arc=[ring[(start+k)%16] for k in range(9)]
                    strength=max(strength,max(0,min(arc)),max(0,-max(arc)))
            scores.append(max(0,strength-1))
    return scores
def oracle(scores,w,h,threshold,keep):
    output=[]
    for i,score in enumerate(scores):
        y,x=divmod(i,w)
        if score<=threshold:reason=1
        elif not keep and (x==0 or y==0 or x==w-1 or y==h-1):reason=2
        else:
            neighborhood=[yy*w+xx for yy in range(max(0,y-1),min(h,y+2)) for xx in range(max(0,x-1),min(w,x+2)) if (xx,yy)!=(x,y)]
            suppressed=any(scores[j]>score or (scores[j]==score and j<i) for j in neighborhood)
            reason=3 if suppressed else 0
        output.append((score,reason))
    return output
def profile(bits,w,h,keep,usefast=False):
    rng=random.Random(bits*100+w*10+h+keep);n=w*h;mx=(1<<bits)-1
    images=[[0]*n,[mx]*n,[i%(mx+1) for i in range(n)],
            [mx if (i%w+i//w)%2==0 else 1 for i in range(n)]]
    spike=[1]*n;spike[(h//2)*w+w//2]=mx;images.append(spike)
    images += [[rng.randrange(mx+1) for _ in range(n)] for _ in range(5)]
    images.append([mx]*n) # Full positive plateau with threshold zero.
    if usefast:
        for dark in [False,True]:
            center=mx//4 if not dark else 3*mx//4;image=[center]*n;cx,cy=w//2,h//2
            for k in range(9):
                dx,dy=CIRCLE[(13+k)%16];image[(cy+dy)*w+cx+dx]=3*mx//4 if not dark else mx//4
            images.append(image)
    thresholds=[0,mx,0,0,mx//2]+[rng.randrange(mx+1) for _ in range(5)]+[0]
    if usefast:thresholds += [0,mx//8]
    maps=[fast_scores(image,w,h) if usefast else image for image in images]
    expected=[oracle(scores,w,h,t,keep) for scores,t in zip(maps,thresholds)]
    with tempfile.TemporaryDirectory(prefix='corner_nms_') as tmp:
        p=pathlib.Path(tmp)
        (p/'input.mem').write_text(''.join(f'{v:x}\n' for image in images for v in image))
        (p/'thresholds.mem').write_text(''.join(f'{t:x}\n' for t in thresholds))
        (p/'geometry.vh').write_text(f'localparam BITS={bits},WIDTH={w},HEIGHT={h},KEEP_BORDER={keep},USE_FAST={int(usefast)},CASES={len(images)};\n')
        execute(['iverilog','-g2012','-I',p,'-s','tb','-o',p/'sim.vvp',HERE/'img_corner_nms.v',FAST,HERE/'tb_img_corner_nms.sv'],p,p/'compile.log')
        text=execute(['vvp',p/'sim.vvp'],p,p/'simulation.log',timeout=120)
        assert f'NMS PASS {w}x{h}' in text,text
    actual=collections.defaultdict(list)
    for line in text.splitlines():
        fields=line.split()
        if fields and fields[0]=='P':actual[int(fields[1])].append(tuple(map(int,fields[3:])))
    for frame,want in enumerate(expected):assert actual[frame]==want,(bits,w,h,keep,usefast,frame,actual[frame],want)
    if not usefast:assert actual[len(images)+1]==[(0,1)]*n,'bad-frame recovery'
    corners=sum(reason==0 for frame in expected for score,reason in frame)
    print(f'NMS PASS BITS={bits} {w}x{h} BORDER={keep} FAST={int(usefast)} frames={len(images)} pixels={len(images)*n} corners={corners}')
    return {'bits':bits,'width':w,'height':h,'keep_border':keep,'fast_chain':usefast,'frames':len(images),'pixels':len(images)*n,'corners':corners,'status':'PASS'}
def main():
    profiles=[profile(*p) for p in [(8,1,1,0),(8,1,1,1),(16,1,7,1),(24,7,1,0),(32,9,7,0),(32,9,7,1),(8,8,6,0),(12,5,5,1),(8,11,9,0,True),(12,9,7,1,True)]]
    (HERE/'test_result.json').write_text(json.dumps({'status':'PASS','profiles':profiles,'rtl_sha256':hashlib.sha256((HERE/'img_corner_nms.v').read_bytes()).hexdigest(),'fast_dependency_sha256':hashlib.sha256(FAST.read_bytes()).hexdigest(),'board_tested':False},indent=2)+'\n')
if __name__=='__main__':main()
