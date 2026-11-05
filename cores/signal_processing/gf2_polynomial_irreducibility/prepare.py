"""Prepare immutable finite fixtures and argv before any HDL authorization."""
from pathlib import Path
import hashlib
import json
import sys
sys.dont_write_bytecode=True
from oracle import certificate,rabin,checkpoints,gcd_probe_states,degree

ROOT=Path(__file__).resolve().parent
REPO=ROOT.parents[2]
PROFILES=[(1,1),(2,2),(3,3),(8,8),(16,8),(30,3),(63,32),(64,32)]
TARGETS=['initial_square_load','square_first','square_middle','square_last',
 'first_square_check','first_checkpoint_load','gcd_initial','gcd_cancel_zero_shift',
 'gcd_cancel_positive_shift','gcd_swap_nonzero','gcd_swap_zero','gcd_done_one',
 'gcd_done_whole_polynomial','gcd_done_proper','after_successful_checkpoint',
 'last_round_square','last_round_check','held_output','actual_next_offer',
 'second_checkpoint_load','third_checkpoint_load','gcd_final_cancellation',
 'middle_round_square']

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def write_json(p,d):p.write_text(json.dumps(d,indent=2,sort_keys=True)+'\n',encoding='utf-8',newline='\n')
def words(seed,d,count):
    mask=(1<<64)-1;x=seed
    for _ in range(count):
        x^=(x<<13)&mask;x^=x>>7;x^=(x<<17)&mask;x&=mask
        yield x&((1<<d)-1)

def main_polynomials(d):
    if d<=8:return list(range(1<<d))
    m=(1<<d)-1
    structural=[0,1,2,3,1<<(d-1),(1<<(d-1))|1,m,
       sum(1<<i for i in range(0,d,2)),sum(1<<i for i in range(1,d,2)),
       5,9,17,(1<<(d//2))|1,(1<<(d-1))-1,(1<<(d//3))|3,
       (1<<(d-1))|(1<<(d//2))|3]
    if d==64:structural[11]=0x1b
    return structural+list(words(0xB26F1E1D5EED1234^d,d,32))

def product(factors):
    result=1
    for factor in factors:
        out=0;a=result;b=factor
        while b:
            if b&1:out^=a
            a<<=1;b>>=1
        result=out
    return result

def fixed_constructions():
    # Complete, fixed finite factor domains; never try-until-success or reseed.
    domains={d:[certificate(poly,d,0) for poly in range(1<<d)] for d in [8,9]}
    factors8=[c for c in domains[8] if c['irreducible']][:8]
    factors9=[c for c in domains[9] if c['irreducible']][:7]
    assert len(factors8)==8 and len(factors9)==7
    products={}
    for d,k,factors in [(64,8,factors8),(63,9,factors9)]:
        values=[(1<<k)|c['poly'] for c in factors]
        assert len(set(values))==len(values)
        f=product(values);assert degree(f)==d
        products[d]=certificate(f^(1<<d),d,0)
    write_json(ROOT/'CONSTRUCTION_CERTIFICATES.json',dict(
        selection='complete fixed monic degree8/9 domains; first8/7 true irreducibles',
        domains={str(d):[dict(poly=c['poly'],irreducible=c['irreducible']) for c in cs] for d,cs in domains.items()},
        factors_degree8=factors8,factors_degree9=factors9,products=products))
    return products

def events(c,d):
    f=(1<<d)|c['poly'];cp=checkpoints(d);result=[]
    for row in c['rounds']:
        i=row['i']
        result.append(dict(state=1,k=i,left=0,u=0,v=0,event='load'))
        for left in sorted(set([d-1,d//2,0]),reverse=True):
            result.append(dict(state=2,k=i,left=left,u=0,v=0,event='square'))
        result.append(dict(state=3,k=i,left=0,u=0,v=0,event='check'))
        if row['checkpoint']:
            result.append(dict(state=4,k=i,left=0,u=0,v=0,event='gcd_load'))
            for j,g in enumerate(gcd_probe_states(f,row['delta'])):
                result.append(dict(state=5,k=i,left=0,initial=j==0,**g))
    result.append(dict(state=6,k=c['index'],left=0,u=0,v=0,event='hold'))
    return result

def matches(t,e,d,poly):
    cp=checkpoints(d);st=e['state'];k=e['k'];ev=e['event'];f=(1<<d)|poly
    tests={0:st==1 and k==1,
      1:st==2 and k==1 and e['left']==d-1,
      2:st==2 and k==1 and e['left']==d//2,
      3:st==2 and k==1 and e['left']==0,
      4:st==3 and k==1,
      5:st==4 and bool(cp) and k==cp[0],
      6:st==5 and e.get('initial',False),
      7:ev=='cancel' and e.get('shift')==0,
      8:ev=='cancel' and e.get('shift',0)>0,
      9:ev=='swap_nonzero',10:ev=='swap_zero',
      11:ev=='done' and e['u']==1,
      12:ev=='done' and e['u']==f,
      13:ev=='done' and e['u'] not in [1,f],
      14:st==1 and bool(cp) and k==cp[0]+1,
      15:st==2 and k==d and e['left']==d-1,
      16:st==3 and k==d,17:st==6,18:st==6,
      19:st==4 and len(cp)>1 and k==cp[1],
      20:st==4 and len(cp)>2 and k==cp[2],
      21:ev=='cancel' and e.get('cancels_to_zero',False),
      22:st==2 and k==(d+1)//2 and e['left']==d//2}
    return tests[t]

def line(c):
    return f"{c['poly']:x} {c['tag']:x} {int(c['irreducible'])} {c['kind']} {c['index']} {c['delta']:x} {c['witness_gcd']:x} {c['cycles']}"

def prepare():
    assert not (ROOT/'TEST_PLAN.json').exists(),'refuse to replace a frozen plan'
    (ROOT/'fixtures').mkdir(exist_ok=True)
    constructions=fixed_constructions()
    profiles=[];children=[];total=0
    iv=str(REPO/'tools/oss-cad-suite/oss-cad-suite/bin/iverilog.exe')
    vvp=str(REPO/'tools/oss-cad-suite/oss-cad-suite/bin/vvp.exe')
    artifacts=REPO/'.git/b26-b-artifacts'
    rtl=str(ROOT/'rtl/gf2_polynomial_irreducibility.sv');tb=str(ROOT/'sim/tb.sv')
    def child(name,argv,expected='PASS',**extra):
        children.append(dict(name=name,argv=argv,cwd=str(ROOT),expected=expected,timeout_seconds=20,**extra))
    for n,(d,t) in enumerate(PROFILES):
        name=f'p{n}';tm=(1<<t)-1
        cases=[certificate(poly,d,(i if i%2==0 else ~i)&tm)
               for i,poly in enumerate(main_polynomials(d))]
        total+=len(cases)
        cache={c['poly']:c for c in cases}
        pool=main_polynomials(d)+(list(words(0xC0FFEEB26D15EA5E^d,d,256)) if d>8 else [])
        if d in constructions:pool.append(constructions[d]['poly'])
        candidates=[]
        for poly in dict.fromkeys(pool):
            c=cache.get(poly) or dict(poly=poly,**rabin(poly,d))
            candidates.append((poly,c,events(c,d)))
        probes=[];excluded=[]
        for target,label in enumerate(TARGETS):
            # Equal first/middle/last positions are declared aliases, not new coverage.
            if d==1 and target in [2,3,22]:
                excluded.append(dict(id=target,label=label,reason='DEGREE=1 aliases the first square step'));continue
            found=next(((p,c,e) for p,c,es in candidates for e in es if matches(target,e,d,p)),None)
            if found is None:
                reason=('no checkpoint for DEGREE=1' if not checkpoints(d) and target in list(range(5,15))+[19,20,21]
                  else 'degree has fewer required distinct-prime checkpoints' if target in [19,20]
                  else 'exhaustive full polynomial domain has no matching reachable state' if d<=8
                  else 'not reached in the immutable 48+256 owner pool; not claimed globally unreachable')
                excluded.append(dict(id=target,label=label,reason=reason));continue
            poly,_,event=found
            owner=certificate(poly,d,(target*13+1)&tm)
            fresh=certificate(0x1b if d==64 else poly^(1<<(target%d)),d,owner['tag']^tm)
            mask=1|(2 if event['state']==2 else 0)|(4 if event['state']==5 else 0)
            predicate={k:event.get(k,0) for k in ['state','k','left','u','v']}
            predicate['mask']=mask
            probes.append(dict(id=target,label=label,predicate=predicate,owner=owner,fresh=fresh,
                               actual_next_offer=target==18))
        mainfile=ROOT/f'fixtures/{name}_main.txt';resetfile=ROOT/f'fixtures/{name}_reset.txt'
        mainfile.write_text(f'{len(cases)} {d} {t}\n'+'\n'.join(line(c) for c in cases)+'\n',encoding='ascii',newline='\n')
        text=[f'{len(probes)} {d} {t}']
        for p in probes:
            x=p['predicate'];text.extend([f"{p['id']} {int(p['actual_next_offer'])}",line(p['owner']),line(p['fresh']),
                f"{x['state']} {x['k']} {x['left']} {x['u']:x} {x['v']:x} {x['mask']}"])
        resetfile.write_text('\n'.join(text)+'\n',encoding='ascii',newline='\n')
        detail=ROOT/f'fixtures/{name}.json'
        write_json(detail,dict(degree=d,tag_w=t,cases=cases,probes=probes,excluded=excluded))
        profiles.append(dict(name=name,degree=d,tag_w=t,main_count=len(cases),reset_count=len(probes),
             checkpoints=checkpoints(d),first_valid_upper=d*(d+2)+len(checkpoints(d))*(3*d+2),
             main_file=mainfile.relative_to(ROOT).as_posix(),main_sha256=sha(mainfile),
             reset_file=resetfile.relative_to(ROOT).as_posix(),reset_sha256=sha(resetfile),
             certificate=detail.relative_to(ROOT).as_posix(),certificate_sha256=sha(detail),excluded=excluded))
        child(name+'_compile',[iv,'-g2012','-Wall','-s','tb',f'-Ptb.D={d}',f'-Ptb.TAG_W={t}','-o',str(artifacts/(name+'.vvp')),rtl,tb],kind='compile',profile=name)
    assert total==462
    child('example_compile',[iv,'-g2012','-Wall','-tnull','-s','gf2_irred16',rtl,str(ROOT/'example/gf2_irred16.sv')],kind='compile')
    for param,value in [('DEGREE',0),('DEGREE',65),('TAG_W',0),('TAG_W',33)]:
        child(f'reject_{param}_{value}',[iv,'-g2012','-tnull','-s','gf2_polynomial_irreducibility',f'-Pgf2_polynomial_irreducibility.{param}={value}',rtl],
              expected='EXPECTED_REJECT',kind='reject',marker='gf2_polynomial_irreducibility_invalid_parameters__see_README')
    for p in profiles:
        exe=str(artifacts/(p['name']+'.vvp'))
        for mode in [0,1]:
            child(f"{p['name']}_main_{mode}",[vvp,exe,f'+MODE={mode}',f"+FILE={ROOT/p['main_file']}"],kind='simulation',profile=p['name'],mode=mode)
        child(p['name']+'_reset',[vvp,exe,'+MODE=2',f"+FILE={ROOT/p['reset_file']}"],kind='simulation',profile=p['name'],mode=2)
    plan=dict(schema=1,baseline='da85338f8a22c454cce77f5b88dd7a803975deb6',
       frozen_before_hdl=True,no_adaptive_splits=True,timeout_seconds=20,timeout_terminal=True,
       profiles=profiles,children=children,oracle_sha256=sha(ROOT/'oracle.py'),preparation_sha256=sha(Path(__file__)),
       probe_selection='first matching immutable main+256 extra pool, plus one fixed algebraic owner at D63/64; no DUT consulted',
       reset_targets=TARGETS,primary='derivative squarefree plus Berlekamp Frobenius-matrix nullity',
       secondary='complete polynomial square and bit-scan full remainder Rabin',small_domain='all monic candidate factors',
       preseal_revision='PRESEAL_RECORD.json',construction_file='CONSTRUCTION_CERTIFICATES.json',
       coverage_expectations=dict(degree64_candidate_irreducible=certificate(0x1b,64,0)['irreducible'],
           whole_polynomial_witness={str(d):c['kind']==1 and c['witness_gcd']==((1<<d)|c['poly']) for d,c in constructions.items()}),
       totals=dict(profiles=8,main_commands=462,main_replays=924,reset_count=sum(p['reset_count'] for p in profiles),
                   simulations=24,compiles=9,expected_rejects=4,children=len(children)))
    assert len(children)==37
    write_json(ROOT/'TEST_PLAN.json',plan)
    print(json.dumps(plan['totals']))

if __name__=='__main__':
    prepare()
