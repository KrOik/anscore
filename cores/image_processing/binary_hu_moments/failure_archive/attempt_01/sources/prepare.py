"""One finite fixture preparation; run only after root authorizes this exact plan."""
import hashlib,json,math
from pathlib import Path
from oracle import hu,EXPONENTS
ROOT=Path(__file__).resolve().parent
PROFILES=((1,1,1),(1,7,32),(7,1,1),(3,3,8),(8,8,8),(32,32,32))
LABELS=('full','first','last','corners','checker','row','column','diag','anti_diag','Lshape',
        'skew','mirror','rot90','translate','noise0','noise1')
BASE=((0,0),(1,0),(2,0),(0,1),(0,2),(1,2))
STATES=('CAPTURE','RAW_STORE','READ_A','READ_B','EXEC','ABS_A','ABS_B','MUL','SIGN_RESULT','WRITE',
        'OUT_NUM','OUT_DEN','OUT_LOAD','OUT_HOLD','ERROR_HOLD')
TARGETS={i:dict(name=name,predicate='state=='+str(i),minimum_N=1) for i,name in enumerate(STATES)}
for i,name,predicate in [
 (15,'CAPTURE_MASKED','state0 && accepted==1 && raw_m00==0'),
 (16,'CAPTURE_FIRST','state0 && accepted==1 && raw_m00==1'),
 (17,'CAPTURE_MIDDLE','state0 && accepted==N/2'),
 (18,'CAPTURE_BEFORE_LAST','state0 && accepted==N-1'),
 (19,'MUL_FIRST','state7 && pc0 && step0'),(20,'MUL_MIDDLE','state7 && pc0 && stepWW/2'),
 (21,'MUL_LAST','state7 && pc0 && stepWW-1'),(22,'FINAL_PRODUCT_MIDDLE','state7 && pc78 && stepWW/2'),
 (23,'RAW_FIRST','state1 && raw_index0'),(24,'RAW_LAST','state1 && raw_index9'),
 (25,'FINAL_READ','state2 && pc78'),(26,'FINAL_WRITE','state9 && pc78'),
 (34,'ACTUAL_NEXT_COMPUTE','state2 && pc0 && actual_fresh_first_blocked'),
 (35,'ACTUAL_NEXT_OUTPUT','state13 && index0 && actual_fresh_first_blocked'),
 (36,'FINAL_PRODUCT_NONZERO_PREFIX','state7 && pc78 && stepWW/2 && mul_acc!=0')]:
    TARGETS[i]=dict(name=name,predicate=predicate,minimum_N=2 if 15<=i<=18 else 1)
for i in range(7):TARGETS[27+i]=dict(name='OUTPUT_'+str(i),predicate='state13 && index'+str(i)+' && retired=='+str(i)+' && !ready',minimum_N=1)
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def write(path,value):path.write_text(json.dumps(value,indent=2,sort_keys=True)+'\n',encoding='utf-8',newline='\n')
def widths(w,h,t):
    n=w*h;a=max(1,(n-1).bit_length());l=max(1,(max(w,h)-1).bit_length());ww=max(12*(a+l)+9,18*a+2);rw=a+3*l+1
    cw=n.bit_length();xw=max(1,(w-1).bit_length());yw=max(1,(h-1).bit_length());sw=(ww-1).bit_length()
    return dict(A=a,L=l,WORK_W=ww,RAW_W=rw,COUNT_W=cw,first_valid=45*ww+464,last_retire=45*ww+489,
                logical_RAM_bits=32*ww,scalar_bits=9*ww+10*rw+18*l+xw+yw+2*cw+t+sw+23)
def pattern(label,w,h):
    points=set(BASE)
    if label=='mirror':points={(w-1-x,y) for x,y in BASE}
    if label=='rot90':points={(h-1-y,x) for x,y in BASE}
    if label=='translate':points={(x+2,y+3) for x,y in BASE}
    out=[]
    for y in range(h):
        for x in range(w):
            choices=dict(full=True,first=(x==y==0),last=(x==w-1 and y==h-1),
              corners=(x in (0,w-1) and y in (0,h-1)),checker=(x+y)%2==0,row=y==h//2,
              column=x==w//2,diag=x==y,anti_diag=x+y==min(w,h)-1,Lshape=x==0 or y==h-1,
              skew=(x,y) in points,mirror=(x,y) in points,rot90=(x,y) in points,translate=(x,y) in points,
              noise0=(x*17+y*11+x*y*3)%7<3,noise1=(x*13+y*19+x*y*7+5)%11<5)
            out.append(int(choices[label]))
    if not any(out):out[0]=1
    return out
def make_case(q,label,tag,pixels,flags=0,prefix=None):
    w,h,t=q['WIDTH'],q['HEIGHT'],q['TAG_W'];n=w*h;tag&=(1<<t)-1
    if flags&1:pixels=[0]*n
    tokens=[]
    for k,bit in enumerate(pixels):
        sof=int(k==0);eol=int(k%w==w-1)
        if flags&2 and k==n-1:sof^=1
        if flags&4 and k==n-1:eol^=1
        tokens.append([bit,sof,eol,int(bool(flags&8) and k==n-1),tag if k==0 else tag^((1<<t)-1)])
    if prefix is not None:tokens=tokens[:prefix]
    complete=len(tokens)==n;area=sum(x[0] for x in tokens);err=0
    for k,(_,sof,eol,bad,_) in enumerate(tokens):
        if sof!=int(k==0):err|=2
        if eol!=int(k%w==w-1):err|=4
        if bad:err|=8
    if complete and not area:err|=1
    outputs=[]
    if complete:
        if err:outputs=[dict(num=0,den=1,contract_den=1,index=0,keep=0,last=1,errors=err,tag=tag,area=area)]
        else:
            mass,values=hu(w,h,[x[0] for x in tokens]);assert mass==area
            outputs=[dict(num=v.numerator,den=v.denominator,contract_den=mass**power,index=k,keep=1,
                          last=int(k==6),errors=0,tag=tag,area=area) for k,(v,power) in enumerate(zip(values,EXPONENTS))]
    return dict(label=label,tokens=tokens,outputs=outputs,tag=tag if tokens else 0,area=area,errors=err,
                complete=complete,first_valid=q['first_valid'] if complete and not err else 0)
def text_case(c):
    lines=[' '.join(map(str,[len(c['tokens']),len(c['outputs']),c['errors'],c['area'],c['tag'],int(c['complete']),c['first_valid']]))]
    lines+=[' '.join(map(str,t)) for t in c['tokens']]
    lines+=[' '.join(str(o[k]) for k in ('num','den','contract_den','index','keep','last','errors','tag','area')) for o in c['outputs']]
    return lines
def fixture(name,data,header,cases):
    jp=ROOT/'fixtures'/f'{name}.json';tp=ROOT/'fixtures'/f'{name}.txt';write(jp,data)
    lines=[header]
    for c in cases:lines+=text_case(c)
    tp.write_text('\n'.join(lines)+'\n',encoding='utf-8',newline='\n')
    return dict(name=name,json=jp.relative_to(ROOT).as_posix(),text=tp.relative_to(ROOT).as_posix(),json_sha256=sha(jp),text_sha256=sha(tp))
def main():
    assert not (ROOT/'TEST_PLAN.json').exists(),'never replace a finite preparation'
    qs=[]
    for p,(w,h,t) in enumerate(PROFILES):
        q=dict(name='p'+str(p),WIDTH=w,HEIGHT=h,TAG_W=t,**widths(w,h,t));n=w*h
        q['cycle_limit']=8*(n+(n+4)//5+45*q['WORK_W']+600)+128
        cases=[make_case(q,label,17+13*k,pattern(label,w,h)) for k,label in enumerate(LABELS)]
        cases += [make_case(q,'flags_'+str(flags),41+7*flags,pattern('noise0',w,h),flags) for flags in range(16)]
        assert len(cases)==32
        q['main']=[];size=1 if p==5 else 4
        for k in range(0,32,size):
            group=cases[k:k+size];name=q['name']+'_main_'+str(k//size).zfill(3)
            d=dict(kind='main',profile=q['name'],frames=group,queued=len(group)-1)
            g=fixture(name,d,'0 '+str(len(group)),group);g.update(frames=len(group),outputs=sum(len(c['outputs']) for c in group),queued=len(group)-1);q['main'].append(g)
        q['resets']=[];q['excluded_reset_targets']={}
        for target,spec in sorted(TARGETS.items()):
            if n<spec['minimum_N']:
                q['excluded_reset_targets'][str(target)]='N=1 has no partial raster acceptance';continue
            tag=73+target*3;bits=pattern('full',w,h);prefix=None;flags=0
            if target==0:prefix=0
            if target==14:flags=1
            if target==15:bits=[0]*n;prefix=1
            if target==16:prefix=1
            if target==17:prefix=n//2
            if target==18:prefix=n-1
            owner=make_case(q,spec['name'],tag,bits,flags,prefix)
            fresh=make_case(q,'fresh_complete_all_seven',tag^((1<<t)-1),pattern('noise1',w,h))
            name=q['name']+'_reset_'+str(target).zfill(3);retired=target-27 if 27<=target<=33 else 0
            d=dict(kind='reset',profile=q['name'],target=target,predicate=spec['predicate'],owner=owner,fresh=fresh,
                   reset_cycles=3,owner_prefix_outputs=retired,actual_next_offer=target in (34,35))
            g=fixture(name,d,'1 '+str(target),[owner,fresh]);g.update(target=target,frames=1,outputs=7,prefix=retired,next=int(target in (34,35)));q['resets'].append(g)
        qs.append(q)
    children=[dict(name='fixture_oracles',argv=['python','-B','oracle.py','--verify-plan','TEST_PLAN.json'],expected='PASS',timeout_seconds=20),
              dict(name='tool_version',argv=['iverilog','-V'],expected='PASS',timeout_seconds=20)]
    rtl=['-Irtl','rtl/binary_hu_moments.sv']
    for name,top,extra in [('core_lint','binary_hu_moments',[]),('example_lint','hu8', ['example/hu8.sv'])]:
        children.append(dict(name=name,argv=['iverilog','-g2012','-Wall','-tnull','-s',top]+rtl+extra,expected='PASS',timeout_seconds=20))
    for q in qs:
        compile=['iverilog','-g2012','-Wall','-s','tb_binary_hu_moments','-o','{TMP}/'+q['name']+'.vvp']
        compile += ['-Ptb_binary_hu_moments.'+key+'='+str(q[key]) for key in ('WIDTH','HEIGHT','TAG_W')]
        compile+=['-Ptb_binary_hu_moments.CYCLE_LIMIT='+str(q['cycle_limit']),'-Isim']+rtl+['sim/tb_binary_hu_moments.sv']
        children.append(dict(name=q['name']+'_compile',argv=compile,expected='PASS',timeout_seconds=20))
        for kind in ('main','resets'):
            for g in q[kind]:children.append(dict(name=g['name'],argv=['vvp','{TMP}/'+q['name']+'.vvp','+INPUT='+g['text']],expected='PASS',timeout_seconds=20))
    rejects=[('w0','WIDTH',0),('w33','WIDTH',33),('h0','HEIGHT',0),('h33','HEIGHT',33),('t0','TAG_W',0),('t33','TAG_W',33)]
    for name,key,v in rejects:children.append(dict(name='reject_'+name,argv=['iverilog','-g2012','-tnull','-s','binary_hu_moments','-Pbinary_hu_moments.'+key+'='+str(v)]+rtl,expected='REJECT_INVALID_PARAMETERS_MARKER',timeout_seconds=20))
    plan=dict(schema=1,baseline='da85338f8a22c454cce77f5b88dd7a803975deb6',phase='FINITE_BEFORE_FIRST_HDL',profiles=qs,
              reset_targets=TARGETS,states={i:s for i,s in enumerate(STATES)},children=children,timeout_seconds=20,
              timeout_terminal=True,ordinary_failure_requires_root_authorization=True,no_adaptive_splits=True,
              oracle_sha256=sha(ROOT/'oracle.py'),preparation_sha256=sha(ROOT/'prepare.py'),
              totals=dict(children=len(children),profiles=6,main_frames=192,main_outputs=804,main_queued=120,main_simulations=72,
                          reset_count=218,fresh_frames=218,fresh_outputs=1526,simulations=290,fixture_files=580,expected_rejects=6))
    assert len(children)==306 and sum(len(q['resets']) for q in qs)==218
    write(ROOT/'TEST_PLAN.json',plan)
    print('PREPARED children=306 simulations=290 main=192 resets=218 SHA256='+sha(ROOT/'TEST_PLAN.json'))
if __name__=='__main__':main()
