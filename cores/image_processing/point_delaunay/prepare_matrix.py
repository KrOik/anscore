"""Original exact rational-circle oracle and immutable pre-RTL finite matrix."""
from collections import Counter
from fractions import Fraction as F
from hashlib import sha256
from itertools import combinations, product
from pathlib import Path
from random import Random
import json
import math

ROOT = Path(__file__).resolve().parent
BASELINE = '20e2db4aded8858ff63e132c2399fb416aa48ed0'
STATES = ['CAPTURE','CHECK','DUP_I','DUP_J','DUP_EVAL','TRI_START','TRI_B',
          'TRI_C','TRI_ADV','ORI_SETUP','ORI_EVAL','QUERY_NEXT','QUERY_SETUP',
          'QUERY_EVAL','TRI_STORE','FINALIZE','OUT_READ','OUT_LOAD','OUT_B',
          'OUT_C','OUT_READY','OUT_HOLD','ZERO_PREP','LOAD_READ','LOAD_LATCH',
          'MUL_RUN','MUL_RET']
TARGETS = ([dict(id=i,name='state_'+s) for i,s in enumerate(STATES)] +
           [dict(id=27+i,name='incircle_return_'+str(i)) for i in range(15)] +
           [dict(id=42+i,name='orientation_return_'+str(i)) for i in range(2)] +
           [dict(id=44+i,name=s) for i,s in enumerate([
               'inside_reject','outside_accept','zero_query_min_reject',
               'zero_fan_accept','zero_fan_reject','negative_orientation',
               'zero_orientation','duplicate_cleared','held_empty','held_point',
               'held_line','held_upstream','held_overflow','held_combined','held_mesh'])])

def orient(a,b,c):
    return (b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0])

def canonical(t,points):
    i,j,k=sorted(t)
    return (i,j,k) if orient(points[i],points[j],points[k])>0 else (i,k,j)

def circle_mesh(points):
    """Independent construction: exact circles, empty sets, boundary gift-wrap fans."""
    distinct={};seen=set()
    for i,p in enumerate(points):
        if p not in seen:
            distinct[i]=p;seen.add(p)
    circles={};triangles=set()
    for i,j,k in combinations(distinct,3):
        a,b,c=distinct[i],distinct[j],distinct[k]
        den=2*orient(a,b,c)
        if not den:continue
        ux,uy=b[0]-a[0],b[1]-a[1];vx,vy=c[0]-a[0],c[1]-a[1]
        uu=ux*ux+uy*uy;vv=vx*vx+vy*vy
        cx=F(a[0])+F(uu*vy-vv*uy,den)
        cy=F(a[1])+F(ux*vv-vx*uu,den)
        radius=(F(a[0])-cx)**2+(F(a[1])-cy)**2
        key=(cx,cy,radius)
        if key in circles:continue
        distances={p:(F(v[0])-cx)**2+(F(v[1])-cy)**2 for p,v in distinct.items()}
        if any(d<radius for d in distances.values()):continue
        boundary=[p for p,d in distances.items() if d==radius]
        circles[key]=boundary
        start=min(boundary,key=lambda p:distinct[p]);ring=[start];current=start
        while True:
            nxt=next(p for p in boundary if p!=current)
            for p in boundary:
                if p!=current and orient(distinct[current],distinct[nxt],distinct[p])<0:nxt=p
            if nxt==start:break
            ring.append(nxt);current=nxt
        pivot=ring.index(min(ring));ring=ring[pivot:]+ring[:pivot]
        for h in range(1,len(ring)-1):
            triangles.add(canonical((ring[0],ring[h],ring[h+1]),distinct))
    mesh=sorted(triangles,key=lambda t:tuple(sorted(t)))
    certificate(distinct,mesh)
    return mesh,len(distinct)

def polygon_area(poly):
    return sum(poly[i][0]*poly[(i+1)%len(poly)][1]-poly[i][1]*poly[(i+1)%len(poly)][0]
               for i in range(len(poly))) if poly else 0

def overlap_area(a,b):
    poly=[(F(x),F(y)) for x,y in a]
    for u,v in zip(b,b[1:]+b[:1]):
        output=[]
        for p,q in zip(poly,poly[1:]+poly[:1]):
            dp=orient(u,v,p);dq=orient(u,v,q)
            if dp>=0:output.append(p)
            if (dp<0 and dq>0) or (dp>0 and dq<0):
                f=dp/(dp-dq)
                output.append((p[0]+f*(q[0]-p[0]),p[1]+f*(q[1]-p[1])))
        poly=output
        if not poly:break
    return polygon_area(poly)

def certificate(points,mesh):
    if not mesh:
        values=list(points.values())
        assert len(values)<3 or all(orient(values[0],values[1],p)==0 for p in values)
        return
    assert {i for t in mesh for i in t}==set(points)
    edges=Counter((t[i],t[(i+1)%3]) for t in mesh for i in range(3))
    boundary=[]
    for a,b in edges:
        assert edges[(a,b)]==1
        if not edges[(b,a)]:
            boundary.append((a,b))
            assert all(orient(points[a],points[b],p)>=0 for p in points.values())
            assert not any(p not in (a,b) and orient(points[a],points[b],q)==0 and
                           min(points[a][0],points[b][0])<=q[0]<=max(points[a][0],points[b][0]) and
                           min(points[a][1],points[b][1])<=q[1]<=max(points[a][1],points[b][1])
                           for p,q in points.items())
    assert len({a for a,b in boundary})==len(boundary)==len({b for a,b in boundary})
    assert len(mesh)==2*len(points)-2-len(boundary)<=2*len(points)-5
    area=sum(orient(points[a],points[b],points[c]) for a,b,c in mesh)
    assert area>0 and area==sum(points[a][0]*points[b][1]-points[a][1]*points[b][0] for a,b in boundary)
    for left,right in combinations(mesh,2):
        assert overlap_area([points[i] for i in left],[points[i] for i in right])==0

def tokens(points,t,mask=False,error=0):
    tagmax=(1<<t)-1
    data=[(x,y,1,0,int(error and i==len(points)//2),(i*17+tagmax)&tagmax)
          for i,(x,y) in enumerate(points)]
    if not data:data=[(0,0,0,0,error,tagmax)]
    if mask:data.insert(0,(0,0,0,0,0,tagmax))
    data[-1]=data[-1][:3]+(1,)+data[-1][4:]
    return data

def expected(data,n):
    points=[];errors=0
    for x,y,keep,last,error,tag in data:
        errors|=2 if error else 0
        if keep:
            if len(points)<n:points.append((x,y))
            else:errors|=1
    mesh,u=([],0) if errors else circle_mesh(points)
    dim=0 if u<2 else (2 if mesh else 1)
    rows=[]
    for index,triangle in enumerate(mesh):
        xy=[v for i in triangle for v in points[i]]
        rows.append(list(triangle)+xy+[len(points),u,len(mesh),index,0,2,1,int(index==0),int(index==len(mesh)-1),data[0][5]])
    if not rows:rows=[[0]*9+[len(points),u,0,0,errors,dim,0,1,1,data[0][5]]]
    assert all(len(row)==19 for row in rows)
    return rows

def fresh(c,n):
    if n==1:return [(0,0)]
    if n==3:return [(-1,-1),(1,-1),(-1,1)]
    if n==4:return [(0,0),(1,0),(1,1),(0,1)]
    if n==8:return [(-3,0),(-2,-2),(0,-3),(2,-2),(3,0),(2,2),(0,3),(-2,2)]
    # Three hull vertices and thirteen strictly interior points attain 2N-5.
    return [(-40,-40),(40,-40),(0,40)]+[(x,y) for y in (-20,-10,0) for x in (-10,-5,0,5,10)][:13]

def owner(target,c,n,t):
    base=fresh(c,n)
    if n>=4:base=[(0,0),(3,0),(0,3),(1,1)]+[(0,0)]*(n-4)
    if target==0:
        d=tokens(base,t);return [(0,0,0,0,0,(1<<t)-1)]+d
    if target in (22,55):return tokens(base,t,error=1)
    if target in (46,47,48):base=[(0,0),(1,0),(1,1),(0,1)]+[(0,0)]*(n-4)
    if target==45:base=[(0,0),(1,0),(0,1),(3,3)]+[(0,0)]*(n-4)
    if target==49:base=[(-1,-1),(-1,1),(1,1)]+[(1,-1)]*(n-3)
    if target==50:base=[(-1,0),(0,0),(1,0)]+[(0,1)]*(n-3)
    if target==51:base=([(0,0),(0,0)]+fresh(c,n))[:n]
    if target==52:return tokens([],t)
    if target==53:base=[(0,0)]*n
    if target==54:base=[(i-(n//2),0) for i in range(n)]
    if target in (56,57):return tokens([(0,0)]*(n+1),t,error=int(target==57))
    return tokens(base,t,mask=True)

def reachable(n):
    if n==1:return [0,1,15,21,22,52,53,55,56,57]
    if n==3:return [i for i in range(59) if i not in set([12,13]+list(range(27,42))+list(range(44,49)))]
    return list(range(59))

def controls(c,n,t):
    lo=-(1<<(c-1));hi=(1<<(c-1))-1
    values=[[],[(lo,lo)],[(hi,hi)]*n,[(lo,hi),(hi,lo)][:n],fresh(c,n),list(reversed(fresh(c,n))),
            [(lo,lo),(hi,lo),(hi,hi),(lo,hi)][:n],[(i-n//2,0) for i in range(n)],
            [(0,0)]*(n+1),[(0,0)]*(n+2)]
    result=[tokens(v,t,mask=i%2==0,error=int(i==9)) for i,v in enumerate(values)]
    result += [tokens(fresh(c,n),t,error=1),tokens([],t,error=1),
               [(lo,hi,0,0,0,(1<<t)-1),(hi,lo,0,1,0,0)],
               tokens([(lo,lo),(hi,hi),(lo,hi)][:n],t),
               tokens([(hi,lo),(lo,hi),(hi,hi)][:n],t),tokens(fresh(c,n),t,mask=True)]
    return result

def main_cases(c,n,t):
    grid=[(x,y) for y in (-1,0,1) for x in (-1,0,1)];rng=Random(230501+n)
    if n==1:values=[[(x,y)] for y in range(-2,2) for x in range(-2,2)]
    elif n in (3,4):values=[list(q) for q in product(grid,repeat=n)]
    elif n==8:
        values=[]
        for mask in range(512):
            selected=[p for i,p in enumerate(grid) if mask>>i&1]
            if len(selected)>8:continue
            rng.shuffle(selected);values.append(selected)
    else:
        ring=[(5,0),(4,3),(3,4),(0,5),(-3,4),(-4,3),(-5,0),(-4,-3),(-3,-4),(0,-5),(3,-4),(4,-3)]
        lo=-(1<<(c-1));hi=(1<<(c-1))-1
        values=[fresh(c,n),list(reversed(fresh(c,n))),ring,list(reversed(ring)),ring+[(0,0)],
                [(x,y) for y in range(4) for x in range(4)],[(i-8,0) for i in range(16)],
                [(lo,lo),(hi,lo),(hi,hi),(lo,hi)]+[(x,y) for y in (-1,0,1) for x in (-1,0,1)],
                grid,[(i-8,(i-8)**2) for i in range(16)]]
        for _ in range(22):values.append([(rng.randrange(lo,hi+1),rng.randrange(lo,hi+1)) for z in range(n)])
    return [tokens(v,t,mask=(i%17==0)) for i,v in enumerate(values)]+controls(c,n,t)

def write(path,lines):
    p=ROOT/path;p.parent.mkdir(parents=True,exist_ok=True)
    b=('\n'.join(lines)+'\n').encode();p.write_bytes(b)
    return sha256(b).hexdigest()

def prepare():
    if (ROOT/'MATRIX.json').exists():raise SystemExit('immutable matrix already exists')
    jobs=[];profiles=[]
    for c,n,t,chunk,reset_chunk in [(2,1,1,100,10),(2,3,3,1000,37),(3,4,8,729,6),(8,8,8,40,5),(12,16,32,2,2)]:
        name=f'c{c}_n{n}_t{t}';cases=main_cases(c,n,t);ids=reachable(n)
        iw=max(1,(n-1).bit_length());cw=max(1,n.bit_length());tm=max(1,2*n-5);tcw=max(1,tm.bit_length())
        bound=32+8*n+6*math.comb(n,2)+(math.comb(n,3)*(35*n-85) if n>=3 else 0)+12*tm
        profiles.append(dict(name=name,c=c,n=n,t=t,frames=len(cases),reset_ids=ids,excluded_reset_ids=[i for i in range(59) if i not in ids],
                             scalar_bits=30*c+11*iw+2*cw+2*tcw+t+n+49,ram_bits=2*c*n+3*iw*tm,tail_bound=bound))
        count=max(math.ceil(len(cases)/chunk),math.ceil(len(ids)/reset_chunk))
        for q in range(count):
            selected=cases[q*chunk:(q+1)*chunk];reset_ids=ids[q*reset_chunk:(q+1)*reset_chunk]
            base=f'{name}_{q:02d}';fpath=f'sim/fixtures/{base}.txt';rpath=f'sim/fixtures/{base}_reset.txt'
            lines=[str(len(selected))];inputs=outputs=0
            for data in selected:
                gold=expected(data,n);lines.append(f'{len(data)} {len(gold)}')
                lines += [' '.join(map(str,row)) for row in data+gold];inputs+=len(data);outputs+=len(gold)
            fsha=write(fpath,lines);rline=[str(len(reset_ids))]
            for target in reset_ids:
                old=owner(target,c,n,t);new=tokens(fresh(c,n),t,mask=True);gold=expected(new,n)
                rline.append(f'{target} {len(old)} {len(new)} {len(gold)}')
                rline += [' '.join(map(str,row)) for row in old+new+gold]
                inputs+=len(old)+len(new);outputs+=len(gold)
            rsha=write(rpath,rline)
            jobs.append(dict(name=base,c=c,n=n,t=t,fixture=fpath,fixture_sha256=fsha,resets=rpath,resets_sha256=rsha,
                             frames=len(selected),reset_ids=reset_ids,inputs=inputs,outputs=outputs,
                             cycle_limit=bound*(len(selected)+2*len(reset_ids))+10*(inputs+outputs)+4096))
    children=['version','core_syntax','example_syntax']
    for j in jobs:children += [j['name']+'_compile',j['name']+'_simulate']
    negatives=[['c1',1,8,8],['c13',13,8,8],['n0',8,0,8],['n17',8,17,8],['t0',8,8,0],['t33',8,8,33]]
    children += ['reject_'+x[0] for x in negatives]
    freeze=dict(baseline=BASELINE,stage='FULL_INPUTS_AND_EXACT_CIRCLE_ORACLE_BEFORE_RTL',timeout_seconds=20,
                profiles=profiles,jobs=jobs,states=STATES,reset_targets=TARGETS,children=children,negatives=negatives,
                oracle='Fraction circumcentres/radii; group all empty circles; boundary gift wrapping; fan from minimum original retained ID; exact rational triangle clipping certificates',
                tie='single global lift z_r=x*x+y*y-epsilon**(r+1), epsilon=2**(-(2*C+5)); nonzero determinants unchanged; minimum-ID negative height cofactor resolves zero',
                reset='first post-edge observed exact target: assert at #2 without an intervening active edge; immediately gate; abort owner; full-capacity fresh mesh every record held >=3 cycles and retired',
                schedule='clocked x/y loads 2 edges; product/consume 2 edges; 2 orientation multiplies or 15 incircle multiplies; all 27 states and every read-q included in paper resource budget',
                no_adaptation=True,timeout_terminal=True,ordinary_failure='archive complete frozen sources/plan/receipt/NOT_RUN before root-authorized repair',
                preparation_sha256=sha256(Path(__file__).read_bytes()).hexdigest(),attribute_sha256=sha256((ROOT/'.gitattributes').read_bytes()).hexdigest())
    write('MATRIX.json',[json.dumps(freeze,indent=2)])
    print('FROZEN',len(jobs),'jobs',len(children),'children',sum(p['frames'] for p in profiles),'main',sum(len(p['reset_ids']) for p in profiles),'resets')
    print('MATRIX_SHA256',sha256((ROOT/'MATRIX.json').read_bytes()).hexdigest())

if __name__=='__main__':prepare()
