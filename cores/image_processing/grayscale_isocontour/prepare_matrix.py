"""One-shot finite inputs and Fraction bilinear-saddle oracle, before any RTL.

No external imports, HDL, random search, package runner, or network dependency.
"""
from collections import Counter
from fractions import Fraction as F
from hashlib import sha256
from itertools import product
from pathlib import Path
import json
import random

ROOT = Path(__file__).resolve().parent
BASELINE = 'b6af9a4c6b843924c6eb4d45b2fdf362dcc8b333'
RESET = {
    0: 'CAPTURE empty address0 before first acceptance',
    1: 'CAPTURE nonempty malformed owned prefix',
    2: 'CHECK successful complete raster',
    3: 'CELL_START',
    4: 'LOAD_READ corner0', 5: 'LOAD_READ corner1',
    6: 'LOAD_READ corner2', 7: 'LOAD_READ corner3',
    8: 'LOAD_LATCH corner0', 9: 'LOAD_LATCH corner1',
    10: 'LOAD_LATCH corner2', 11: 'LOAD_LATCH corner3',
    12: 'CLASSIFY no crossings', 13: 'CLASSIFY two crossings',
    14: 'CLASSIFY four crossings', 15: 'MUL_A', 16: 'MUL_SAVE',
    17: 'MUL_B', 18: 'DECIDE positive determinant',
    19: 'DECIDE negative determinant',
    20: 'DECIDE zero determinant corner0 high',
    21: 'DECIDE zero determinant corner0 low',
    22: 'MAKE single-segment cell',
    23: 'HOLD single-segment cell after three holds',
    24: 'HOLD ambiguous first segment after three holds',
    25: 'MAKE ambiguous second segment',
    26: 'HOLD ambiguous second segment after three holds',
    27: 'ADV cell row wrap before final row',
    28: 'ADV final cell',
    29: 'SUMMARY_PREP successful nonempty graph',
    30: 'SUMMARY_HOLD successful nonempty graph after three holds',
    31: 'SUMMARY_HOLD successful empty graph after three holds',
    32: 'CHECK combined framing/upstream errors',
    33: 'SUMMARY_PREP combined errors',
    34: 'SUMMARY_HOLD combined errors after three holds',
}
PROFILES = [(1,1,1,1),(1,7,8,3),(7,1,3,8),(2,2,1,1),(2,2,2,8),
            (3,3,3,8),(5,4,5,5),(16,16,8,8),(64,64,12,32)]

def digest(p): return sha256(p.read_bytes()).hexdigest()
def save(p, obj): p.write_bytes((json.dumps(obj, indent=2)+'\n').encode())
def cw(n): return max(1, (n-1).bit_length())

def oracle(pixels, w, h, level):
    """Evaluate the bilinear critical point directly; no RTL pairing/Q table.

    Each alternating cell isolates the corner sign opposite to its saddle.
    A saddle exactly at the level isolates the high corners (level+epsilon).
    Fractions describe edge interpolation; chords only encode branch pairing.
    """
    records=[]; nodes=Counter(); encodings={}; stats=Counter(); ambiguous=0
    incidences=((0,3),(0,1),(1,2),(2,3))
    for y in range(h-1):
        for x in range(w-1):
            a,b,c,d=[F(pixels[q])-F(2*level+1,2)
                     for q in (y*w+x,y*w+x+1,(y+1)*w+x+1,(y+1)*w+x)]
            z=(a,b,c,d); stats['sign_'+str(sum((v>0)<<i for i,v in enumerate(z)))]+=1
            definitions=((0,x,y,a,b),(1,x+1,y,b,c),(0,x,y+1,d,c),(1,x,y,a,d))
            endpoints={}
            for edge,(axis,bx,by,u,v) in enumerate(definitions):
                if (u>0)==(v>0):continue
                fraction=-u/(v-u)
                assert 0<fraction<1
                den=int(2*abs(v-u)); num=fraction*den
                assert num.denominator==1 and 0<num<den
                encoded=(axis,bx,by,int(num),den)
                position=(F(bx)+(fraction if axis==0 else 0),F(by)+(fraction if axis else 0))
                endpoints[edge]=(encoded,position)
            assert len(endpoints) in (0,2,4)
            if not endpoints:continue
            if len(endpoints)==2:
                pairs=[tuple(endpoints)]
            else:
                ambiguous+=1
                mixed=a-b+c-d
                sx=(a-d)/mixed; sy=(a-b)/mixed
                assert 0<sx<1 and 0<sy<1
                saddle=a*(1-sx)*(1-sy)+b*sx*(1-sy)+c*sx*sy+d*(1-sx)*sy
                isolate_high=saddle<=0
                pairs=[tuple(sorted(incidences[i])) for i,v in enumerate(z) if (v>0)==isolate_high]
                pairs.sort()
                stats['saddle_'+('positive' if saddle>0 else 'negative' if saddle<0 else 'zero')+
                      ('_a_high' if a>0 else '_a_low')]+=1
            local=[]
            for e0,e1 in pairs:
                assert e0<e1
                p0,c0=endpoints[e0];p1,c1=endpoints[e1]
                assert c0!=c1
                local.append((c0,c1))
                for enc in (p0,p1):
                    key=enc[:3];nodes[key]+=1
                    assert key not in encodings or encodings[key]==enc
                    encodings[key]=enc
                records.append((*p0,*p1))
            if len(local)==2:
                def orient(p,q,r):return (q[0]-p[0])*(r[1]-p[1])-(q[1]-p[1])*(r[0]-p[0])
                u,v=local[0];s,t=local[1]
                assert not (orient(u,v,s)*orient(u,v,t)<0 and orient(s,t,u)*orient(s,t,v)<0)
    expected={}
    if w>1 and h>1:
        for axis in (0,1):
            for y in range(h-(axis==1)):
                for x in range(w-(axis==0)):
                    q=y*w+x;r=q+(1 if axis==0 else w)
                    u=F(pixels[q])-F(2*level+1,2);v=F(pixels[r])-F(2*level+1,2)
                    if (u>0)!=(v>0):
                        expected[(axis,x,y)]=1 if (y in (0,h-1) if axis==0 else x in (0,w-1)) else 2
    assert dict(nodes)==expected, 'complete shared-edge degrees, including boundary paths'
    assert sum(nodes.values())==2*len(records)
    return records,ambiguous,dict(stats),len(nodes)

def frame(w,h,g,t,pixels,level,tag,mode='good',serial=0):
    n=w*h;mask=(1<<t)-1;tag &= mask
    inputs=[];errors=0
    for i,pixel in enumerate(pixels):
        sof=int(i==0);eol=int(i%w==w-1);error=0
        if mode=='sof_first' and i==0:sof^=1
        if mode=='sof_later' and i==(1 if n>1 else 0):sof^=1
        if mode=='eol_first' and i==0:eol^=1
        if mode=='eol_last' and i==n-1:eol^=1
        if mode=='upstream' and i==n//2:error=1
        if mode=='combined' and i==0:sof^=1;eol^=1;error=1
        if mode=='partial_bad' and i==0:sof^=1
        errors |= (sof!=(i==0)) | ((eol!=(i%w==w-1))<<1) | (error<<2)
        inputs.append((pixel,sof,eol,error,level if i==0 else ((level+i+1)&((1<<g)-1)),
                       tag if i==0 else ((tag+11*i+1)&mask)))
    if errors:segments=[];ambiguous=0;stats={};nodes=0;cells=0
    else:
        segments,ambiguous,stats,nodes=oracle(pixels,w,h,level);cells=(w-1)*(h-1)
    outputs=[(*record,i,0,int(i==0),0,0,tag) for i,record in enumerate(segments)]
    outputs.append((0,0,0,0,0,0,0,0,0,0,len(segments),1,int(not segments),1,errors,tag))
    tail=3+11*cells+2*len(segments)+4*ambiguous
    return dict(inputs=inputs,outputs=outputs,tail=tail,cells=cells,ambiguous=ambiguous,
                segments=len(segments),errors=errors,tag=tag,stats=stats,nodes=nodes,serial=serial)

def patterns(w,h,g):
    high=(1<<g)-1;mid=(high-1)//2;n=w*h
    checker=[high if (x+y)%2==0 else 0 for y in range(h) for x in range(w)]
    rng=random.Random(0xB240000+w*65536+h*256+g)
    return [([0]*n,0,'good'),([high]*n,0,'good'),([high]*n,high,'good'),
            ([high if x else 0 for y in range(h) for x in range(w)],mid,'good'),
            ([high if y else 0 for y in range(h) for x in range(w)],mid,'good'),
            ([min(x,y,w-1-x,h-1-y)*high//max(1,min(w,h)//2) for y in range(h) for x in range(w)],mid,'good'),
            (checker,mid,'good'),([high-v for v in checker],mid,'good'),
            ([rng.randrange(high+1) for _ in range(n)],high//3,'good'),
            ([0 if i%2==0 else high for i in range(n)],max(0,high-1),'good'),
            (checker,mid,'sof_first'),(checker,mid,'sof_later'),
            (checker,mid,'eol_first'),(checker,mid,'eol_last'),
            (checker,mid,'upstream'),(checker,mid,'combined')]

def reset_ids(w,h,g):
    allowed=[];excluded={}
    for i in RESET:
        reason=None
        if i==1 and w*h==1:reason='N1 has no nonempty partial capture'
        if 3<=i<=30 and (w==1 or h==1):reason='no 2x2 cells, so no numerical/segment states'
        if i in (18,19) and g==1:reason='binary half-level alternating cells have only zero saddles'
        if i==27 and h<3:reason='cell grid has no nonfinal cell row'
        if reason:excluded[str(i)]=reason
        else:allowed.append(i)
    return allowed,excluded

def owner(w,h,g,t,rid):
    high=(1<<g)-1;mid=(high-1)//2;n=w*h
    p=[high if (x+y)%2==0 else 0 for y in range(h) for x in range(w)];level=mid;mode='good'
    if rid==1:mode='partial_bad'
    if rid in (12,27,31):p=[0]*n;level=0
    if rid in (13,22,23):p=[0 if x==0 else high for y in range(h) for x in range(w)]
    if rid in (18,19):
        p=[0]*n;level=0
        a,b,c,d=(1,0,high,0) if rid==18 else (0,1,0,high)
        p[0],p[1],p[w+1],p[w]=a,b,c,d
    if rid==21:p=[high-v for v in p]
    if rid in (32,33,34):mode='combined'
    return frame(w,h,g,t,p,level,0x51+rid,mode,10000+rid)

def write_fixture(path,main,resets):
    blocks=[(0,-1,f) for f in main]
    for rid,owned,fresh in resets:blocks.extend([(1,rid,owned),(2,rid,fresh)])
    lines=[f'{len(main)} {len(resets)} {len(blocks)}']
    totals=Counter()
    for kind,rid,f in blocks:
        lines.append(' '.join(map(str,(kind,rid,len(f['outputs']),f['tail'],f['cells'],f['ambiguous'],f['segments'],f['errors'],f['tag']))))
        lines.extend(' '.join(map(str,row)) for row in f['inputs'])
        lines.extend(' '.join(map(str,row)) for row in f['outputs'])
        totals['inputs']+=len(f['inputs']);totals['outputs']+=len(f['outputs'])
        totals['cycle_limit']+=2*len(f['inputs'])+f['tail']+3*len(f['outputs'])+20
    path.write_bytes(('\n'.join(lines)+'\n').encode())
    return dict(inputs=totals['inputs'],outputs=totals['outputs'],cycle_limit=totals['cycle_limit']+100,
                frames=len(main),reset_ids=[r[0] for r in resets],blocks=len(blocks),
                fixture=path.relative_to(ROOT).as_posix(),fixture_sha256=digest(path),
                main_records=sum(len(f['outputs']) for f in main),
                fresh_records=sum(len(r[2]['outputs']) for r in resets))

def main():
    if (ROOT/'MATRIX.json').exists():raise SystemExit('matrix already frozen; no regeneration')
    assert not list(ROOT.rglob('*.sv')) and not list(ROOT.rglob('*.v')), 'matrix must predate every RTL/TB'
    (ROOT/'fixtures').mkdir(exist_ok=True)
    profiles=[];jobs=[];serial=0;allstats=Counter()
    for w,h,g,t in PROFILES:
        name=f'w{w}_h{h}_g{g}_t{t}';frames=[]
        for p,level,mode in patterns(w,h,g):
            frames.append(frame(w,h,g,t,p,level,7+serial*29,mode,serial));serial+=1
        if (w,h,g)==(2,2,1) or (w,h,g)==(2,2,2):
            for p in product(range(1<<g),repeat=4):
                for level in range(1<<g):
                    frames.append(frame(w,h,g,t,p,level,7+serial*29,'good',serial));serial+=1
        if (w,h,g)==(3,3,3):
            for mask in range(512):
                for level in (0,3,6):
                    p=[7 if mask>>i&1 else 0 for i in range(9)]
                    frames.append(frame(w,h,g,t,p,level,7+serial*29,'good',serial));serial+=1
        ids,excluded=reset_ids(w,h,g)
        x,y,a,s=cw(w),cw(h),cw(w*h),cw(2*(w-1)*(h-1)+1)
        profile=dict(name=name,w=w,h=h,g=g,t=t,frames=len(frames),reset_ids=ids,excluded=excluded,
                     scalar_bits=14*g+3*x+3*y+a+s+t+41,ram_bits=g*w*h,
                     tail_bound=19*(w-1)*(h-1)+3,reset_fresh='complete same-geometry max/zero checkerboard at central half-level',
                     main_certificates=dict(Counter({})))
        profile_stats=Counter()
        for f in frames:profile_stats.update(f['stats'])
        profile['main_certificates']=dict(profile_stats);allstats.update(profile_stats)
        profiles.append(profile)
        groups=[frames] if w<64 else [frames[:2]]+[[f] for f in frames[2:]]
        for index,group in enumerate(groups):
            j=write_fixture(ROOT/'fixtures'/f'{name}_main{index:02d}.txt',group,[])
            jobs.append(dict(name=f'{name}_main{index:02d}',w=w,h=h,g=g,t=t,**j))
        fresh_pixels=[(1<<g)-1 if (xx+yy)%2==0 else 0 for yy in range(h) for xx in range(w)]
        resets=[(rid,owner(w,h,g,t,rid),frame(w,h,g,t,fresh_pixels,((1<<g)-2)//2,0xA6+rid,'good',20000+rid)) for rid in ids]
        groups=[resets] if w<64 else [[r] for r in resets]
        for index,group in enumerate(groups):
            j=write_fixture(ROOT/'fixtures'/f'{name}_reset{index:02d}.txt',[],group)
            jobs.append(dict(name=f'{name}_reset{index:02d}',w=w,h=h,g=g,t=t,**j))
    negatives=[['width0',0,16,8,8],['width65',65,16,8,8],['height0',16,0,8,8],['height65',16,65,8,8],
               ['gray0',16,16,0,8],['gray13',16,16,13,8],['tag0',16,16,8,0],['tag33',16,16,8,33]]
    children=['version','core_syntax','example_syntax']
    for job in jobs:children.extend([job['name']+'_compile',job['name']+'_simulate'])
    children.extend('reject_'+q[0] for q in negatives)
    matrix=dict(baseline=BASELINE,stage='COMPLETE_FIXTURES_ORACLE_RESETS_SPLITS_BEFORE_ANY_RTL',
                preparation_sha256=digest(Path(__file__)),attribute_sha256=digest(ROOT/'.gitattributes'),
                timeout_seconds=20,timeout_terminal=True,no_adaptation=True,source_gap_period=7,output_holds_per_record=3,
                oracle='stdlib Fraction direct bilinear critical point interpolation + isolated-corner connectivity; shared-edge degree/noncrossing certificates',
                regularization='one positive level epsilon limit; high disconnected at exact saddle; endpoints use original-level limiting fractions',
                reset_targets={str(k):v for k,v in RESET.items()},profiles=profiles,jobs=jobs,negatives=negatives,children=children,
                totals=dict(main_frames=sum(p['frames'] for p in profiles),resets=sum(len(p['reset_ids']) for p in profiles),
                            jobs=len(jobs),children=len(children),stored_inputs=sum(j['inputs'] for j in jobs),
                            stored_outputs=sum(j['outputs'] for j in jobs),main_records=sum(j['main_records'] for j in jobs),
                            fresh_records=sum(j['fresh_records'] for j in jobs)),certificates=dict(allstats),
                max_split='first two constant empty graphs share one main child (each cheaper than half a checkerboard pair); every remaining main frame separate; every reset ID separate')
    assert matrix['totals']['main_frames']==2736
    assert set(k for k in allstats if k.startswith('sign_'))=={'sign_'+str(i) for i in range(16)}
    for polarity in ('a_high','a_low'):
        for sign in ('positive','negative','zero'):assert allstats['saddle_'+sign+'_'+polarity]>0
    save(ROOT/'MATRIX.json',matrix)
    print('MATRIX_FROZEN',digest(ROOT/'MATRIX.json'),json.dumps(matrix['totals'],sort_keys=True))

if __name__=='__main__': main()
