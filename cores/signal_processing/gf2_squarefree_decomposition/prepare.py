"""One root-approved fixed preparation, before any HDL authorization."""
from pathlib import Path
import argparse,hashlib,json,sys
sys.dont_write_bytecode=True
from oracle import certificate,multiply,power
from timing import walk,compute_bound,target_flags,predicate,TARGETS,HOLD,GCD_STEP,DIV_STEP,LAYER

ROOT=Path(__file__).resolve().parent
REPO=ROOT.parents[2]
PROFILES=[(1,1),(5,3),(16,8),(64,32)]
SEED=0xB27F5FD12EED1234
STRUCTURAL_LABELS=['x_power','x_plus_one_power','low_x','squarefree_sparse',
 'low_x2_plus_one','low_x3_plus_one','low_x4_plus_one','top_low_bit',
 'top_low_and_constant','all_low_bits','even_coefficients','odd_coefficients',
 'quadratic_power','quartic_power','degree8_power','linear_high_odd_left',
 'linear_high_odd_right','same_even_multiplicity','mixed_odd_even','many_groups']

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):return json.loads(p.read_bytes())
def write(p,data):p.write_text(json.dumps(data,indent=2,sort_keys=True)+'\n',encoding='utf-8',newline='\n')
def words(seed,d,count):
    mask=(1<<64)-1;x=seed
    for _ in range(count):
        x^=x<<13&mask;x^=x>>7;x^=x<<17&mask;x&=mask
        yield x&((1<<d)-1)
def product(parts):
    f=1
    for factor,exponent in parts:f=multiply(f,power(factor,exponent))
    return f
def main_inputs(d):
    if d<=5:return [(str(i),i) for i in range(1<<d)]
    top=1<<d
    values=[0,1,2,3,5,9,17,1<<(d-1),(1<<(d-1))|1,top-1,
            sum(1<<i for i in range(0,d,2)),sum(1<<i for i in range(1,d,2))]
    constructions=[[(7,d//2)],[(0x13,d//4)],[(0x11b,d//8)],
      [(2,d-1),(3,1)],[(2,1),(3,d-1)],[(2,d//2),(3,d//2)],
      [(2,2),(3,4),(7,5)] if d==16 else [(2,3),(3,5),(7,28)],
      [(2,3),(3,3),(7,5)] if d==16 else [(2,1),(3,2),(7,3),(0xb,4),(0xd,5),(0x13,7)]]
    for parts in constructions:
        f=product(parts);assert f.bit_length()-1==d;values.append(f^top)
    assert len(values)==20
    return list(zip(STRUCTURAL_LABELS,values,strict=True))+[(f'fixed_seed_{i}',p) for i,p in enumerate(words(SEED^d,d,8))]

def add_timing(c,d):
    held=[];metrics=dict(gcd_cancels=0,gcd_swaps=0,gcd_done=0,div_cancels=0,div_done=0,roots=0)
    for event in walk(c,d):
        if event['state']==HOLD:held.append(event)
        add_metric(metrics,event)
    assert len(held)==len(c['factors'])
    for factor,event in zip(c['factors'],held,strict=True):
        factor.update(gap=event['gap'],last=event['last'])
    c['always_ready_final_retirement']=held[-1]['cycle']+1
    c['compute_bound']=compute_bound(d)
    c['metrics']=metrics
    assert c['always_ready_final_retirement']<=compute_bound(d)+d
    return c

def add_metric(metrics,event):
    if event['state']==GCD_STEP:
        metrics['gcd_done' if event['v']==0 else 'gcd_swaps' if event['u']==0 or event['u'].bit_length()<event['v'].bit_length() else 'gcd_cancels']+=1
    if event['state']==DIV_STEP:metrics['div_done' if event['u']==0 else 'div_cancels']+=1
    if event['state']==LAYER and event['w']==1 and event['c']>1:metrics['roots']+=1

def command_lines(c):
    lines=[f"{c['poly']:x} {c['tag']:x} {len(c['factors'])}"]
    lines.extend(f"{x['factor']:x} {x['multiplicity']} {x['degree']} {int(x['last'])} {x['gap']}" for x in c['factors'])
    return lines

def prepare(approved):
    prep=ROOT/'PREPARATION_PLAN.json'
    assert sha(prep)==approved,'exact root-approved preparation plan required'
    spec=read(prep)
    assert spec['profiles']==[list(x) for x in PROFILES] and spec['fixed_seed']==SEED
    assert spec['main_frames']==90 and spec['hdl_children']==21 and spec['timeout_seconds']==20
    assert all(sha(ROOT/k)==v for k,v in spec['source_sha256'].items())
    assert not (ROOT/'TEST_PLAN.json').exists() and not (ROOT/'SOURCE_FREEZE.json').exists() and not (ROOT/'verification.json').exists()
    assert not (ROOT/'fixtures').exists()
    (ROOT/'fixtures').mkdir()
    profiles=[];children=[];total=0
    iv=str(REPO/'tools/oss-cad-suite/oss-cad-suite/bin/iverilog.exe')
    vvp=str(REPO/'tools/oss-cad-suite/oss-cad-suite/bin/vvp.exe')
    artifacts=REPO/'.git/b27-b-artifacts'
    rtl=str(ROOT/'rtl/gf2_squarefree_decomposition.sv');tb=str(ROOT/'sim/tb.sv')
    def child(name,argv,kind,expected='PASS',**extra):
        children.append(dict(name=name,argv=argv,cwd=str(ROOT),kind=kind,expected=expected,timeout_seconds=20,**extra))
    for number,(d,t) in enumerate(PROFILES):
        name=f'p{number}';tm=(1<<t)-1
        cases=[]
        for i,(label,poly) in enumerate(main_inputs(d)):
            c=add_timing(certificate(poly,d,(i if i%2==0 else ~i)&tm),d)
            if label=='many_groups' and d==64:assert [x['multiplicity'] for x in c['factors']]==[1,3,5,7,2,4]
            c['label']=label;cases.append(c)
        assert len(cases)==(1<<d if d<=5 else 28)
        selected={}
        for index,c in enumerate(cases):
            if len(selected)==len(TARGETS):break
            for event in walk(c,d):
                for target,flag in enumerate(target_flags(event,d)):
                    if flag and target not in selected:selected[target]=(index,predicate(event),event['cycle'])
        expected_excluded=[4,8,10,11,12,14] if d==1 else []
        assert sorted(set(range(16))-set(selected))==expected_excluded,'fixed pool coverage differs; stop, never expand or reseed'
        probes=[];excluded=[]
        for target,label in enumerate(TARGETS):
            if target not in selected:
                excluded.append(dict(id=target,label=label,reason='complete degree1 monic domain cannot reach this predicate'));continue
            index,pred,target_cycle=selected[target]
            owner=dict(cases[index]);owner['tag']=(target*13+1)&tm
            poly=(1-owner['poly']) if d==1 else (5 if d==5 else 3)
            if poly==owner['poly']:poly=3 if d==5 else 7
            fresh=add_timing(certificate(poly,d,owner['tag']^tm),d)
            assert fresh['poly']!=owner['poly'] and fresh['tag']!=owner['tag'] and len(fresh['factors'])==1
            prefix_metrics={k:0 for k in owner['metrics']}
            for event in walk(owner,d):
                if event['cycle']==target_cycle:break
                add_metric(prefix_metrics,event)
            probes.append(dict(id=target,label=label,owner_case=index,owner=owner,fresh=fresh,predicate=pred,
                 owner_target_cycle=target_cycle,owner_prefix_metrics=prefix_metrics,
                 actual_next_offer=target==13,
                 note='degree1 next-offer uses its only final factor; nonfinal target is globally impossible' if d==1 and target==13 else ''))
        assert len(probes)==(10 if d==1 else 16)
        main=ROOT/f'fixtures/{name}_main.txt';reset=ROOT/f'fixtures/{name}_reset.txt';detail=ROOT/f'fixtures/{name}.json'
        lines=[f'{len(cases)} {d} {t}']
        for c in cases:lines.extend(command_lines(c))
        main.write_text('\n'.join(lines)+'\n',encoding='ascii',newline='\n')
        lines=[f'{len(probes)} {d} {t}']
        for p in probes:
            x=p['predicate'];lines.append(f"{p['id']} {int(p['actual_next_offer'])}")
            lines.extend(command_lines(p['owner']));lines.extend(command_lines(p['fresh']))
            lines.append(' '.join(str(int(x[k])) for k in ['mask','state','operation','iteration','level','retired','last']))
            lines.append(' '.join(f'{x[k]:x}' for k in ['u','v','q','c','w','z']))
        reset.write_text('\n'.join(lines)+'\n',encoding='ascii',newline='\n')
        write(detail,dict(degree=d,tag_w=t,cases=cases,probes=probes,excluded=excluded))
        profile=dict(name=name,degree=d,tag_w=t,main_count=len(cases),reset_count=len(probes),compute_upper=compute_bound(d),
             main_file=main.relative_to(ROOT).as_posix(),main_sha256=sha(main),reset_file=reset.relative_to(ROOT).as_posix(),reset_sha256=sha(reset),
             certificate=detail.relative_to(ROOT).as_posix(),certificate_sha256=sha(detail),excluded=excluded,
             main_factors=sum(len(c['factors']) for c in cases),owner_prefix_factors=sum(p['predicate']['retired'] for p in probes),
             fresh_factors=sum(len(p['fresh']['factors']) for p in probes))
        profiles.append(profile);total+=len(cases)
        child(name+'_compile',[iv,'-g2012','-Wall','-s','tb',f'-Ptb.D={d}',f'-Ptb.TAG_W={t}','-o',str(artifacts/(name+'.vvp')),rtl,tb],'compile',profile=name)
    assert total==90
    child('example_compile',[iv,'-g2012','-Wall','-tnull','-s','gf2_sfd16',rtl,str(ROOT/'example/gf2_sfd16.sv')],'compile')
    for param,value in [('DEGREE',0),('DEGREE',65),('TAG_W',0),('TAG_W',33)]:
        child(f'reject_{param}_{value}',[iv,'-g2012','-tnull','-s','gf2_squarefree_decomposition',f'-Pgf2_squarefree_decomposition.{param}={value}',rtl],
              'reject','EXPECTED_REJECT',marker='gf2_squarefree_decomposition_invalid_parameters__see_README')
    for p in profiles:
        exe=str(artifacts/(p['name']+'.vvp'))
        for mode in [0,1,2]:
            child(p['name']+('_reset' if mode==2 else f'_main_{mode}'),
                  [vvp,exe,f'+MODE={mode}',f"+FILE={ROOT/p['reset_file' if mode==2 else 'main_file']}"],
                  'simulation',profile=p['name'],mode=mode)
    assert len(children)==21
    totals=dict(profiles=4,main_frames=90,main_replays=180,reset_count=58,simulations=12,compiles=5,expected_rejects=4,children=21,
        main_retired_factors=2*sum(p['main_factors'] for p in profiles),owner_prefix_factors=sum(p['owner_prefix_factors'] for p in profiles),
        fresh_factors=sum(p['fresh_factors'] for p in profiles))
    write(ROOT/'TEST_PLAN.json',dict(schema=1,baseline=spec['baseline'],frozen_before_hdl=True,no_adaptive_splits=True,
       timeout_seconds=20,timeout_terminal=True,preparation_plan_sha256=approved,preparation_sha256=sha(Path(__file__)),
       oracle_sha256=sha(ROOT/'oracle.py'),timing_sha256=sha(ROOT/'timing.py'),profiles=profiles,children=children,reset_targets=TARGETS,
       primary='full deterministic Berlekamp split, repeated original-polynomial division multiplicities',
       secondary='characteristic2 squarefree decomposition',small_domain='all monic candidate factors for D<=5',
       probe_selection='first matching event in the same immutable main pool; no extra candidates or DUT consulted',totals=totals))
    print(json.dumps(totals))

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--approved-plan',required=True)
    prepare(parser.parse_args().approved_plan)
