"""Independent flood-fill oracle; compares partitions and component statistics."""
import collections,hashlib,json,os,pathlib,random,shutil,subprocess,tempfile
HERE=pathlib.Path(__file__).resolve().parent
def execute(cmd,cwd):
    env=os.environ.copy();oss=HERE.parents[3]/'tools/oss-cad-suite/oss-cad-suite'
    if oss.exists():env['PATH']=os.pathsep.join([str(oss/'bin'),str(oss/'lib'),env.get('PATH','')])
    cmd[0]=shutil.which(cmd[0],path=env['PATH']) or cmd[0]
    r=subprocess.run(cmd,cwd=cwd,env=env,capture_output=True,text=True,timeout=120)
    if r.returncode:raise RuntimeError(r.stdout[-8000:]+r.stderr)
    return r.stdout+r.stderr
def flood(image,w,h,conn):
    labels=[0]*(w*h);components={}
    offsets=[(-1,0),(1,0),(0,-1),(0,1)]
    if conn==8:offsets +=[(-1,-1),(1,-1),(-1,1),(1,1)]
    for start,on in enumerate(image):
        if not on or labels[start]:continue
        label=len(components)+1;points=[];q=collections.deque([start]);labels[start]=label
        while q:
            p=q.popleft();y,x=divmod(p,w);points.append((x,y))
            for dx,dy in offsets:
                xx,yy=x+dx,y+dy
                if 0<=xx<w and 0<=yy<h:
                    k=yy*w+xx
                    if image[k] and not labels[k]:labels[k]=label;q.append(k)
        xs,ys=zip(*points);components[label]=(len(points),min(xs),max(xs),min(ys),max(ys))
    return labels,components
def profile(w,h,conn,cap):
    rng=random.Random(w*100+h+conn);n=w*h
    images=[[0]*n,[1]*n,[int((i%w)==(i//w)) for i in range(n)],
            [int(((i%w)+(i//w))%2==0) for i in range(n)],
            [int(i//w==h//2 or i%w%2==0) for i in range(n)]]
    isolated=[y*w+x for y in range(0,h,2) for x in range(0,w,2)]
    for k in [cap,cap+1]:images.append([int(i in isolated[:k]) for i in range(n)])
    images += [[int(rng.random()<density) for _ in range(n)] for density in [.1,.25,.45,.65,.9] for _ in range(2)]
    oracles=[flood(image,w,h,conn) for image in images]
    codes=[2 if len(stats)>cap else 0 for labels,stats in oracles]
    with tempfile.TemporaryDirectory(prefix='ccl_') as tmp:
        p=pathlib.Path(tmp)
        (p/'input.mem').write_text(''.join(f'{v:x}\n' for image in images for v in image))
        (p/'codes.mem').write_text(''.join(f'{code:x}\n' for code in codes))
        (p/'geometry.vh').write_text(f'localparam WIDTH={w},HEIGHT={h},CONNECTIVITY={conn},LABEL_BITS=4,MAX_LABELS={cap},CASES={len(images)};\n')
        execute(['iverilog','-g2012','-I',str(p),'-s','tb','-o',str(p/'sim.vvp'),str(HERE/'img_connected_components.v'),str(HERE/'tb_img_connected_components.sv')],p)
        output=execute(['vvp',str(p/'sim.vvp')],p)
        assert f'CCL PASS {w}x{h} C={conn}' in output,output
    actual=collections.defaultdict(list);reported=collections.defaultdict(dict)
    for line in output.splitlines():
        fields=line.split()
        if fields and fields[0]=='P':actual[int(fields[1])].append(int(fields[3]))
        if fields and fields[0]=='S':
            values=list(map(int,fields[1:]));f,label,*stats=values
            assert label not in reported[f],'duplicate statistics label'
            reported[f][label]=tuple(stats)
    for f,((gold,stats),code) in enumerate(zip(oracles,codes)):
        if code:assert not actual[f] and not reported[f];continue
        assert len(actual[f])==n
        mapping={0:0};reverse={0:0}
        for expected,label in zip(gold,actual[f]):
            assert 0<=label<=cap
            assert mapping.setdefault(expected,label)==label,'split component'
            assert reverse.setdefault(label,expected)==expected,'aliased components'
        assert reported[f]=={mapping[k]:v for k,v in stats.items()},(w,h,conn,f,reported[f],stats)
    print(f'CCL PASS {w}x{h} C={conn} frames={len(images)} overflow={codes.count(2)}')
    return {'width':w,'height':h,'connectivity':conn,'max_labels':cap,'frames':len(images),'overflow_frames':codes.count(2),'status':'PASS'}
def main():
    profiles=[profile(w,h,c,cap) for w,h,cap in [(1,1,1),(5,5,7),(9,7,7)] for c in [4,8]]
    (HERE/'test_result.json').write_text(json.dumps({'status':'PASS','profiles':profiles,'rtl_sha256':hashlib.sha256((HERE/'img_connected_components.v').read_bytes()).hexdigest(),'board_tested':False},indent=2)+'\n')
if __name__=='__main__':main()
