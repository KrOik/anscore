"""Original pre-RTL fixtures: unweighted feasibility plus global cycle cancellation."""
from collections import Counter, deque
from hashlib import sha256
from itertools import combinations, product
import json
from pathlib import Path
from random import Random

ROOT = Path(__file__).resolve().parent
BASELINE = 'b6af9a4c6b843924c6eb4d45b2fdf362dcc8b333'
PROFILES = [(2,1,1,1,1),(3,3,2,2,3),(4,6,3,4,8),
            (5,12,4,4,8),(8,16,8,8,8),(16,32,8,8,32)]
STATES = ['IDLE','LOAD','CHECK','INIT','EDGE_READ','EDGE_USE','SRC_READ',
          'SRC_USE','DST_READ','DST_USE','RELAX_WRITE','NEXT_ARC','PASS_DONE',
          'SINK_READ','SINK_USE','TRACE_INIT','NODE_READ','NODE_USE',
          'TRACE_EDGE_READ','TRACE_EDGE_USE','PATH_WRITE','TRACE_NEXT',
          'UPDATE_INIT','PATH_READ','PATH_USE','UPDATE_EDGE_READ','UPDATE_EDGE_USE',
          'UPDATE_WRITE','UPDATE_NEXT','AUGMENT_DONE','SUM_INIT','SUM_READ',
          'SUM_PRODUCT','SUM_ADD','OUT_READ','OUT_USE','HOLD']
TARGETS = ([{'id':i,'name':'state_'+s} for i,s in enumerate(STATES)] +
           [{'id':37+i,'name':s} for i,s in enumerate([
               'accepted_command_before_rows','partial_kept_capture',
               'overflow_before_tail','held_terminal_range_error',
               'held_equal_terminal_error','held_endpoint_error','held_upstream_error',
               'held_all_input_errors','reachable_negative_reverse_arc',
               'reverse_augmentation_write','held_shortfall','held_zero_target',
               'held_final_after_prior_retirement','later_cost_accumulation',
               'later_bellman_ford_pass','full_path_bank','blocked_next_command'])])

def encoded(x):
    return (json.dumps(x,sort_keys=True,indent=2)+'\n').encode('utf-8')

def residual(n,edges,flow):
    arcs=[]
    for i,(u,v,cap,cost) in enumerate(edges):
        if flow[i]<cap:arcs.append((u,v,cap-flow[i],cost,i,1))
        if flow[i]:arcs.append((v,u,flow[i],-cost,i,-1))
    return arcs

def negative_cycle(n,arcs):
    """Enumerate simple cycles; no shortest source-to-sink solver or RAM phases."""
    adjacency=[[] for _ in range(n)]
    for a in arcs:adjacency[a[0]].append(a)
    for start in range(n):
        def visit(v,seen,path,cost):
            for arc in adjacency[v]:
                w=arc[1];total=cost+arc[3]
                if w==start:
                    if total<0:return path+[arc]
                elif w>start and w not in seen:
                    found=visit(w,seen|{w},path+[arc],total)
                    if found:return found
            return None
        found=visit(start,{start},[],0)
        if found:return found
    return None

def cut_value(n,edges,source,sink):
    other=[v for v in range(n) if v not in (source,sink)]
    best=None
    for mask in range(1<<len(other)):
        side={source}|{v for i,v in enumerate(other) if mask>>i&1}
        value=sum(cap for u,v,cap,cost in edges if u in side and v not in side)
        if best is None or value<best:best=value
    return best

def certificate(n,edges,source,sink,limit,flow):
    assert len(flow)==len(edges)
    balance=[0]*n;cost=0
    for f,(u,v,cap,w) in zip(flow,edges):
        assert isinstance(f,int) and 0<=f<=cap
        balance[u]+=f;balance[v]-=f;cost+=f*w
    value=balance[source]
    assert value>=0 and balance[sink]==-value
    assert all(balance[v]==0 for v in range(n) if v not in (source,sink))
    assert value==min(limit,cut_value(n,edges,source,sink))
    # Floyd-Warshall independently certifies global residual cycle optimality.
    d=[[None]*n for _ in range(n)]
    for v in range(n):d[v][v]=0
    for u,v,cap,w,*_ in residual(n,edges,flow):
        if d[u][v] is None or w<d[u][v]:d[u][v]=w
    for k in range(n):
        for i in range(n):
            if d[i][k] is None:continue
            for j in range(n):
                if d[k][j] is None:continue
                cand=d[i][k]+d[k][j]
                if d[i][j] is None or cand<d[i][j]:d[i][j]=cand
    assert all(d[v][v]>=0 for v in range(n))
    return value,cost

def oracle(n,edges,source,sink,limit):
    """Find any feasible maximum requested flow, then cancel global cost cycles."""
    wanted=min(limit,cut_value(n,edges,source,sink));flow=[0]*len(edges);value=0
    while value<wanted:
        arcs=residual(n,edges,flow);adj=[[] for _ in range(n)]
        for a in arcs:adj[a[0]].append(a)
        parent={source:None};q=deque([source])
        while q and sink not in parent:
            u=q.popleft()
            for arc in adj[u]:
                v=arc[1]
                if v not in parent:parent[v]=arc;q.append(v)
        assert sink in parent
        path=[];v=sink
        while v!=source:path.append(parent[v]);v=parent[v][0]
        amount=min(wanted-value,*[a[2] for a in path])
        for *_,i,sign in path:flow[i]+=sign*amount
        value+=amount
    cancellations=0
    while True:
        cycle=negative_cycle(n,residual(n,edges,flow))
        if cycle is None:break
        amount=min(a[2] for a in cycle)
        before=sum(f*e[3] for f,e in zip(flow,edges))
        for *_,i,sign in cycle:flow[i]+=sign*amount
        after=sum(f*e[3] for f,e in zip(flow,edges));assert 0<=after<before
        cancellations+=1
    actual=certificate(n,edges,source,sink,limit,flow)
    assert actual[0]==wanted
    choices=1
    for e in edges:choices*=e[2]+1
    direct=False
    if choices<=4096:
        best=None
        for candidate in product(*(range(e[2]+1) for e in edges)):
            bal=[0]*n
            for f,(u,v,cap,w) in zip(candidate,edges):bal[u]+=f;bal[v]-=f
            if bal[source]!=wanted or bal[sink]!=-wanted:continue
            if any(bal[v] for v in range(n) if v not in (source,sink)):continue
            cost=sum(f*e[3] for f,e in zip(candidate,edges))
            if best is None or cost<best:best=cost
        assert best==actual[1];direct=True
    return dict(flow=actual[0],cost=actual[1],reference_flows=flow,
                negative_cycle_cancellations=cancellations,direct_enumeration=direct)

def bound(n,m,capacity,value=None):
    a=m*((1<<capacity)-1) if value is None else value
    return 2+(a+1)*(n+4+(n-1)*(20*m+4))+a*(16*(n-1)+8)+4+3*m

def chain(n,m,cap,cost=1):
    edges=[(u,u+1,cap,cost) for u in reversed(range(n-1))]
    # Tiny M profiles may have fewer than N-1 slots only in other future domains.
    assert len(edges)<=m
    return edges+[(i%n,i%n,cap,cost) for i in range(m-len(edges))]

def reroute(n,m,cost):
    assert n>=4 and m>=5
    # Strict ties choose 0->1->2->3 before the direct alternatives. The second
    # unit then needs reverse 2->1, proving cancellation of original edge1.
    data=[(0,1,1,0),(1,2,1,cost),(2,3,1,0),(0,2,1,cost),(1,3,1,cost)]
    return data+[(i%n,i%n,0,0) for i in range(m-5)]

def rows(edges,error=False):
    data=[list(e)+[1,0,0] for e in edges]
    if not data:data=[[0,0,0,0,0,0,0]]
    data[-1][5]=1;data[-1][6]=int(error)
    return data

def errors(n,m,source,sink,data):
    e=int(source>=n or sink>=n)|(int(source==sink)<<1)
    kept=0
    for u,v,cap,w,keep,last,upstream in data:
        if keep:
            e|=4*int(u>=n or v>=n);kept+=1
        e|=16*upstream
    return e|(8 if kept>m else 0)

def case(n,m,c,w,t,source,sink,limit,data,kind,tag):
    err=errors(n,m,source,sink,data)
    assert data[-1][5] and not any(r[5] for r in data[:-1])
    edges=[tuple(r[:4]) for r in data if r[4]][:m]
    result=dict(flow=0,cost=0,reference_flows=[],negative_cycle_cancellations=0,direct_enumeration=False)
    if not err:result=oracle(n,edges,source,sink,limit)
    return dict(command=[source,sink,limit,tag],rows=data,edges=edges,error=err,
                expected=result,kind=kind,outputs=len(edges) if not err and edges else 1,
                latency_bound=bound(n,m,c,result['flow']) if not err else 1)

def main_cases(n,m,c,w,t):
    rng=Random(0xB240F10+n*31+m);cm=(1<<c)-1;wm=(1<<w)-1;out=[]
    def add(edges,limit,kind,source=0,sink=None,data=None):
        sink=n-1 if sink is None else sink
        data=rows(edges) if data is None else data
        out.append(case(n,m,c,w,t,source,sink,limit,data,kind,rng.getrandbits(t)))
    for limit in (0,1,0xffffffff):add([],limit,'empty')
    for limit in (0,1,cm,cm+1,0xffffffff):add([(0,n-1,cm,wm)],limit,'direct_extreme')
    for limit in (cm,cm+1):add(chain(n,m,cm),limit,'full_capacity_chain')
    add([(i%n,i%n,cm,wm) for i in range(m)],0xffffffff,'all_self_loops')
    add([(0,n-1,cm,(i*13)&wm) for i in range(m)],0xffffffff,'parallel_costs')
    add([(0,n-1,cm,(i*13)&wm) for i in reversed(range(m))],cm+1,'reordered_parallel')
    if m>=2:add([(0,n-1,cm,wm),(n-1,0,cm,0)],0xffffffff,'antiparallel')
    if n>=4 and m>=5:
        for limit in (1,2,3):add(reroute(n,m,wm),limit,'reverse_reroute',sink=3)
        add([(1,2,cm,0),(2,1,cm,wm)],cm,'disconnected_cycle')
    add([],1,'masked_invalid_ignored',data=[[0xffffffff,0xffffffff,cm,wm,0,1,0]])
    for pattern in range(32):
        source,sink=(0,n-1)
        if pattern&1:source=0xffffffff
        if pattern&2:sink=source
        data=[[0xffffffff if pattern&4 else 0,n-1,0,wm,1,0,0]]
        if pattern&8:data += [[0,n-1,0,0,1,0,0] for _ in range(m)]
        data += [[0xffffffff,0xffffffff,cm,wm,0,1,int(bool(pattern&16))]]
        add([],1,'all_input_error_masks',source,sink,data)
        assert out[-1]['error']==pattern
    bad=rows([(0,n-1,0,0)]*m);bad[-1][5]=0
    bad += [[0xffffffff,0xffffffff,cm,wm,1,0,0],[0,0,0,0,0,1,1]]
    add([],1,'late_error_after_full_capacity',data=bad)
    if n==2:
        for u,v,cap,cost in product(range(2),range(2),range(2),range(2)):
            for source,sink in ((0,1),(1,0)):
                for limit in (0,1,2,0xffffffff):add([(u,v,cap,cost)],limit,'exhaustive_one_edge',source,sink)
    elif n==3:
        arcs=[(u,v) for u in range(n) for v in range(n) if u!=v]
        for chosen in combinations(arcs,3):
            for values in product(((0,0),(1,0),(1,1)),repeat=3):
                edges=[(u,v,cap,cost) for (u,v),(cap,cost) in zip(chosen,values)]
                for limit in (1,2):add(edges,limit,'exhaustive_three_arc_modes')
    elif n==4:
        arcs=[(0,1),(0,2),(1,2),(2,1),(1,3),(2,3)]
        for caps in product(range(2),repeat=6):
            for limit in (1,2,0xffffffff):add([(u,v,cap,(i*3)&wm) for i,((u,v),cap) in enumerate(zip(arcs,caps))],limit,'exhaustive_binary_capacity')
    for k in range(12):
        edges=[(rng.randrange(n),rng.randrange(n),rng.randrange(min(cm,7)+1),rng.randrange(wm+1)) for _ in range(m)]
        add(edges,rng.choice([0,1,2,7,0xffffffff]),'seeded_multigraph')
    return out

def reachable(n,m):
    excluded=set()
    if n<4 or m<5:excluded|={45,46}
    if m==1:excluded|={49,50}
    if n==2:excluded.add(51)
    return [i for i in range(54) if i not in excluded]

def owner(target,n,m,c,w,t):
    cm=(1<<c)-1;wm=(1<<w)-1;source,sink,limit=0,n-1,cm+1
    data=rows(chain(n,m,cm));kind='reset_chain_owner'
    if target in (45,46):data=rows(reroute(n,m,wm));sink=3;limit=2
    if target==37:data=[[0,0,0,0,0,0,0]]
    if target==38:data=[[0,n-1,cm,wm,1,0,0]]
    if target==39:data=[[0,n-1,0,0,1,0,0] for _ in range(m+1)]
    if target==40:source=0xffffffff
    if target==41:sink=source
    if target==42:data=rows([(0xffffffff,n-1,cm,wm)])
    if target==43:data=rows(chain(n,m,cm),True)
    if target==44:
        source=sink=0xffffffff
        data=[[0xffffffff,0xffffffff,cm,wm,1,0,0] for _ in range(m+1)]+[[0,0,0,0,0,1,1]]
    if target==48:limit=0
    # Cancel-only owners need not have a tail; no expected output is consumed.
    return dict(command=[source,sink,limit,((1<<t)-1)],rows=data,kind=kind)

def prepare():
    path=ROOT/'TEST_PLAN.json'
    if path.exists():raise SystemExit('immutable pre-RTL matrix already exists')
    profiles=[];children=['version','core syntax','example syntax'];files={}
    for n,m,c,w,t in PROFILES:
        name=f'n{n}_m{m}_c{c}_w{w}_t{t}';cases=main_cases(n,m,c,w,t)
        # Error/zero-flow groups are cheap by mathematical structure, fixed now.
        cheap=[x for x in cases if x['error'] or x['expected']['flow']==0]
        work=[x for x in cases if not x['error'] and x['expected']['flow']]
        size={2:128,3:128,4:32,5:8,8:2,16:1}[n]
        groups=[cheap[i:i+64] for i in range(0,len(cheap),64)]+[work[i:i+size] for i in range(0,len(work),size)]
        children.append(name+' compile TB');main=[]
        for i,group in enumerate(groups):
            rel=f'fixtures/{name}_{i:02d}.json';raw=encoded(dict(N=n,M=m,C=c,W=w,T=t,cases=group));files[rel]=raw
            main.append(dict(fixture=rel,sha256=sha256(raw).hexdigest(),frames=len(group),
                             rows=sum(len(x['rows']) for x in group),outputs=sum(x['outputs'] for x in group)))
            children.append(name+' main '+str(i))
        ids=reachable(n,m);reset=[]
        fresh=case(n,m,c,w,t,0,n-1,cm if (cm:=(1<<c)-1) else 1,rows(chain(n,m,cm)),
                   'full_capacity_fresh',5&((1<<t)-1))
        for i in range(0,len(ids),2):
            group=ids[i:i+2];rel=f'fixtures/{name}_reset_{i//2:02d}.json'
            raw=encoded(dict(N=n,M=m,C=c,W=w,T=t,targets=[dict(id=q,owner=owner(q,n,m,c,w,t),fresh=fresh) for q in group]));files[rel]=raw
            reset.append(dict(fixture=rel,sha256=sha256(raw).hexdigest(),targets=group));children.append(name+' reset '+str(i//2))
        v=max(1,(n-1).bit_length());e=max(1,(m-1).bit_length());dw=w+(((n-1)*2*m+1).bit_length())+1
        profiles.append(dict(name=name,N=n,M=m,C=c,W=w,T=t,main=main,resets=reset,reset_ids=ids,
                             excluded_reset_ids=[x for x in range(54) if x not in ids],
                             coverage=dict(Counter(x['kind'] for x in cases)),main_frames=len(cases),
                             main_rows=sum(len(x['rows']) for x in cases),main_outputs=sum(x['outputs'] for x in cases),
                             direct_enumeration=sum(x['expected']['direct_enumeration'] for x in cases),
                             reference_cycle_cancellations=sum(x['expected']['negative_cycle_cancellations'] for x in cases),
                             latency_bound=bound(n,m,c),distance_bits=dw,
                             ram_bits=m*(2*v+2*c+w)+n*(dw+e+2)+(n-1)*(e+1)))
    rejects=[(p,x) for p,lo,hi in [('NUM_NODES',1,17),('MAX_EDGES',0,33),('CAP_W',0,9),('COST_W',0,9),('TAG_W',0,33)] for x in (lo,hi)]
    children += [f'reject {p}={v}' for p,v in rejects]
    plan=dict(schema=1,baseline_commit=BASELINE,frozen_before_any_rtl=True,timeout_seconds=20,
              profiles=profiles,states=STATES,reset_targets=TARGETS,children=children,rejections=rejects,
              primary_oracle='unweighted feasibility to requested min-cut value, then global negative-simple-cycle cancellation',
              certificates='all source-side cuts; full capacity/conservation/cost; independent Floyd-Warshall global residual no-negative-cycle; direct allocation enumeration <=4096 combinations',
              reset='first falling-edge target observation immediately asserts reset before next active edge; full M-edge N-1-path fresh every complete output retired',
              timeout_terminal=True,no_adaptive_splits=True,
              preparation_sha256=sha256(Path(__file__).read_bytes()).hexdigest())
    (ROOT/'fixtures').mkdir(exist_ok=True)
    for rel,raw in files.items():(ROOT/rel).write_bytes(raw)
    path.write_bytes(encoded(plan))
    print(json.dumps(dict(plan_sha256=sha256(path.read_bytes()).hexdigest(),profiles=len(profiles),
                          children=len(children),fixtures=len(files),main_frames=sum(p['main_frames'] for p in profiles),
                          rows=sum(p['main_rows'] for p in profiles),outputs=sum(p['main_outputs'] for p in profiles),
                          resets=sum(len(p['reset_ids']) for p in profiles),
                          direct_enumeration=sum(p['direct_enumeration'] for p in profiles),
                          reference_cycle_cancellations=sum(p['reference_cycle_cancellations'] for p in profiles)),sort_keys=True))

if __name__=='__main__':prepare()
