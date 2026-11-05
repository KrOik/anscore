"""Fixed finite BFS/deletion certificates; never import the RTL backend oracle."""
from pathlib import Path
import argparse,collections,hashlib,json
P=Path(__file__).resolve().parent.parent
BASELINE='548ecff2b34281ec7b6f3306ba1c8d3af07f246d'
PROFILES=[(1,1),(2,32),(7,3),(16,8),(64,32)]
def write(p,d):p.write_text(json.dumps(d,indent=2,sort_keys=True)+'\n',encoding='utf-8',newline='\n')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def reachable(rows,start,skip=None):
    seen=1<<start;frontier=seen
    while frontier:
        bit=frontier & -frontier;frontier^=bit;u=bit.bit_length()-1
        nxt=rows[u]
        if skip is not None and skip[0]==u:nxt &= ~(1<<skip[1])
        nxt &= ~seen;seen|=nxt;frontier|=nxt
    return seen
def certificate(n,tokens):
    rows=[0]*n;bad=False
    for t in tokens:
        if t['keep']:
            if t['u']>=n or t['v']>=n:bad=True
            elif t['present']:rows[t['u']] |= 1<<t['v']
            else:rows[t['u']] &= ~(1<<t['v'])
    indegree=[sum(bool(row&(1<<v)) for row in rows) for v in range(n)]
    pending=collections.deque(v for v in range(n) if not indegree[v]);visited=0
    while pending:
        u=pending.popleft();visited+=1
        for v in range(n):
            if rows[u]&(1<<v):
                indegree[v]-=1
                if not indegree[v]:pending.append(v)
    err=1 if bad else 2 if visited!=n else 0
    closure=[reachable(rows,u) for u in range(n)]
    result=[0]*n
    if not err:
        for u in range(n):
            for v in range(n):
                if rows[u]&(1<<v) and not reachable(rows,u,(u,v))&(1<<v):result[u]|=1<<v
        # Independent defining certificates: subgraph, identical reachability,
        # and every remaining edge essential under actual edge deletion.
        assert all(not(result[u]&~rows[u]) and reachable(result,u)==closure[u] for u in range(n))
        for u in range(n):
            for v in range(n):
                if result[u]&(1<<v):assert not reachable(result,u,(u,v))&(1<<v)
    original=sum(x.bit_count() for x in rows);reduced=sum(x.bit_count() for x in result)
    return dict(adjacency=rows,reachability=closure,reduced=result,errors=err,
                edges=0 if err else reduced,removed=0 if err else original-reduced,outputs=1 if err else n)
def cases(n,t):
    mask=(1<<t)-1;specs=[]
    def add(name,updates):specs.append((name,updates or [(0xffffffff,0xffffffff,0,0)]))
    chain=[(i,i-1,1,1) for i in range(n-1,0,-1)]
    dense=[(u,v,1,1) for u in range(n-1,-1,-1) for v in range(u)]
    add('empty_masked_first_tag',[(0xffffffff,0x80000000,1,0)])
    add('descending_chain',chain)
    add('complete_reverse_order_DAG',dense)
    diamond=[(3,2,1,1),(3,1,1,1),(2,0,1,1),(1,0,1,1),(3,0,1,1)] if n>=4 else chain
    add('diamond_shortcut',diamond)
    toggles=[(0,0,1,1),(0,0,0,1)]+chain+[(n-1,0,1,1),(n-1,0,0,1)]+chain if n>1 else [(0,0,1,1),(0,0,0,1)]
    add('last_assignment_wins_and_loop_delete',toggles)
    add('positive_cycle',[(0,0,1,1)] if n==1 else [(0,1,1,1),(1,0,1,1)])
    add('explicit_loop',chain+[(n//2,n//2,1,1)])
    add('bad_full32_insert',chain+[(0xffffffff,0,1,1),(0,0,0,0)])
    add('bad_full32_delete',[(0,0x80000000,0,1)]+chain)
    add('masked_bad_updates',[(0xffffffff,0xffffffff,1,0)]+dense+[(0xffffffff,0xffffffff,0,0)])
    for seed in (0x13579bdf,0x2468ace1):
        x=seed;edges=[]
        order=list(range(n))[::2]+list(range(n))[1::2]
        for a in range(n):
            for b in range(a+1,n):
                x=(1664525*x+1013904223)&0xffffffff
                if x>>30:edges.append((order[a],order[b],1,1))
        add('fixed_DAG_'+hex(seed),edges)
    if n==2:
        for bits in range(16):add('all_N2_matrix_'+str(bits),[(u,v,1,1) for u in range(2) for v in range(2) if bits&(1<<(2*u+v))])
    # Dedicated reset owners/fresh use multiple real input tokens even at N1.
    add('reset_owner_full_DAG',[(0,0,1,1),(0,0,0,1)]+dense+[(0xffffffff,0xffffffff,0,0)])
    add('reset_error_owner',[(0xffffffff,0,1,1),(0,0,0,0)])
    add('reset_fresh_full_graph',[(0xffffffff,0xffffffff,1,0)]+dense+[(0,0,0,0)])
    result=[]
    for index,(name,updates) in enumerate(specs):
        tag=(index*0x9e3779b9+0x814125a7)&mask
        tokens=[dict(u=u,v=v,present=p,keep=k,last=int(j==len(updates)-1),
                     tag=tag if not j else (tag+j*17)&mask) for j,(u,v,p,k) in enumerate(updates)]
        cert=certificate(n,tokens)
        result.append(dict(name=name,tokens=tokens,tag=tag,**cert))
    return result
def reset_targets(n,cs):
    owner=next(i for i,c in enumerate(cs) if c['name']=='reset_owner_full_DAG')
    error=next(i for i,c in enumerate(cs) if c['name']=='reset_error_owner')
    fresh=next(i for i,c in enumerate(cs) if c['name']=='reset_fresh_full_graph')
    targets=[]
    # Fixed concrete predicates, never adapt to a simulation observation.
    for state in (1,2,3,4,8,9,11,12,14,15):
        if n==1 and state in (8,9):continue
        targets.append(dict(name='wrapper_'+str(state),state=state,backend=-1,prefix=0,held=0,owner=owner,fresh=fresh))
    for backend in (8,12,13):
        targets.append(dict(name='backend_'+str(backend),state=4,backend=backend,prefix=0,held=0,owner=owner,fresh=fresh))
    targets.append(dict(name='held_error_and_next_offer',state=15,backend=-1,prefix=0,held=3,owner=error,fresh=fresh))
    targets.append(dict(name='held_normal_and_next_offer',state=15,backend=-1,prefix=0,held=3,owner=owner,fresh=fresh))
    if n>1:targets.append(dict(name='after_retired_prefix_and_next_offer',state=15,backend=-1,prefix=1,held=3,owner=owner,fresh=fresh))
    return targets
def text_fixture(n,cs,targets):
    total=sum(len(c['tokens']) for c in cs)
    lines=[f'{len(cs)} {total} {len(targets)}']
    for c in cs:
        lines.append(f"{len(c['tokens'])} {c['outputs']} {c['errors']} {c['tag']:x} {c['edges']} {c['removed']}")
        lines.extend(f'{a:x} {r:x} {z:x}' for a,r,z in zip(c['adjacency'],c['reachability'],c['reduced']))
        lines.extend(f"{q['u']:x} {q['v']:x} {q['present']} {q['keep']} {q['last']} {q['tag']:x}" for q in c['tokens'])
    lines.extend(f"{x['state']} {x['backend']} {x['prefix']} {x['held']} {x['owner']} {x['fresh']}" for x in targets)
    return '\n'.join(lines)+'\n'
def build():
    profiles=[];children=[]
    exe='tools/oss-cad-suite/oss-cad-suite/bin/'
    children.extend([dict(name='fixture_certificates',kind='oracle',argv=['python','-B','sim/prepare.py','--verify']),
                     dict(name='tool_version',kind='version',argv=['iverilog','-V'])])
    for name,top,files in [('core_lint','dag_transitive_reduction','files.f'),('example_lint','dag_reduce16','example/files.f')]:
        children.append(dict(name=name,kind='lint',argv=['iverilog','-g2012','-Wall','-tnull','-s',top,'-f',files]))
    for i,(n,t) in enumerate(PROFILES):
        cs=cases(n,t);targets=reset_targets(n,cs)
        profile=dict(name=f'p{i}',N=n,T=t,json=f'fixtures/p{i}.json',txt=f'fixtures/p{i}.txt',
                     cases=len(cs),tokens=sum(len(c['tokens']) for c in cs),outputs=sum(c['outputs'] for c in cs),
                     resets=len(targets),bound=7*n*n+12*n+8,cycle_limit=1500000 if n==64 else 200000)
        profiles.append(profile)
        children.append(dict(name=f'p{i}_compile',kind='compile',profile=i,
            argv=['iverilog','-g2012','-Wall','-s','tb_dag_transitive_reduction','-o',f'{{TMP}}/p{i}.vvp',
                  f'-Ptb_dag_transitive_reduction.NUM_NODES={n}',f'-Ptb_dag_transitive_reduction.TAG_W={t}',
                  '-f','files.f','sim/tb_dag_transitive_reduction.sv']))
        for mode in (0,1,2):children.append(dict(name=f'p{i}_mode{mode}',kind='simulation',profile=i,mode=mode,
            argv=['vvp','-n',f'{{TMP}}/p{i}.vvp',f'+FIXTURE={profile["txt"]}',f'+MODE={mode}',f'+LIMIT={profile["cycle_limit"]}']))
    for param,value in [('NUM_NODES',0),('NUM_NODES',65),('TAG_W',0),('TAG_W',33)]:
        children.append(dict(name=f'reject_{param}_{value}',kind='reject',argv=['iverilog','-g2012','-tnull',
         '-s','dag_transitive_reduction',f'-Pdag_transitive_reduction.{param}={value}','-f','files.f']))
    for c in children:c['timeout_seconds']=20
    assert len(children)==28
    return dict(schema=1,baseline=BASELINE,profiles=profiles,children=children,
        totals=dict(profiles=5,children=28,simulations=15,named_rejects=4,
                    main_cases=sum(p['cases'] for p in profiles),main_replays=2*sum(p['cases'] for p in profiles),
                    resets=sum(p['resets'] for p in profiles)))
def prepare():
    assert not (P/'TEST_PLAN.json').exists() and not (P/'fixtures').exists()
    plan=build();(P/'fixtures').mkdir()
    for p in plan['profiles']:
        cs=cases(p['N'],p['T']);targets=reset_targets(p['N'],cs)
        assert p['tokens']<32768 and p['cases']<64 and p['N']*p['cases']<4096
        write(P/p['json'],dict(N=p['N'],T=p['T'],cases=cs,targets=targets))
        (P/p['txt']).write_text(text_fixture(p['N'],cs,targets),encoding='utf-8',newline='\n')
    write(P/'TEST_PLAN.json',plan)
    print(json.dumps(dict(status='PREPARED',totals=plan['totals'],plan_sha256=sha(P/'TEST_PLAN.json'))))
def verify():
    plan=json.loads((P/'TEST_PLAN.json').read_bytes());assert plan==build()
    for p in plan['profiles']:
        raw=json.loads((P/p['json']).read_bytes());cs=cases(p['N'],p['T']);targets=reset_targets(p['N'],cs)
        assert raw==dict(N=p['N'],T=p['T'],cases=cs,targets=targets)
        assert (P/p['txt']).read_bytes()==text_fixture(p['N'],cs,targets).encode()
    print('PASS fixed BFS edge-deletion certificates profiles=5')
if __name__=='__main__':
    a=argparse.ArgumentParser();g=a.add_mutually_exclusive_group(required=True)
    g.add_argument('--prepare',action='store_true');g.add_argument('--verify',action='store_true');x=a.parse_args()
    if x.prepare:prepare()
    else:verify()
