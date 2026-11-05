"""Original fixed-case input builder and independent direct-tour oracle.

This entrypoint is NOT_RUN until a separately reviewed single preparation gate.
It never imports RTL, a DUT result, an external solver or the subset recurrence.
"""
from pathlib import Path
import hashlib,json,sys

P=Path(__file__).resolve().parent
def read(n):return json.loads((P/n).read_bytes())
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()

def inputs(name,n,w,tag_w,ordinal):
    low=-(1<<(w-1));high=(1<<(w-1))-1
    def edge(a,b,c,present=1,keep=1):return [a,b,c,present,keep,0,0]
    def ring(value):return [edge(i,(i+1)%n,value(i) if callable(value) else value) for i in range(n)]
    if name=='empty_graph':beats=[edge(0,0,0,0,0)]
    elif name=='missing_return':beats=ring(0)[:-1]
    elif name=='zero_cycle':beats=ring(0)
    elif name=='negative_cycle':beats=ring(-1)
    elif name in ('signed_extrema_cycle','forced_extrema_ring'):
        beats=ring(lambda i:low if i%2==0 else high)
    elif name=='last_assignment_wins':
        beats=ring(1)+[edge(0,1,low),edge(0,1,0,0),edge(0,1,high)]
    elif name=='deletion_removes_only_tour':beats=ring(1)+[edge(0,1,low,0)]
    elif name=='high_endpoint_reject':beats=ring(0)+[edge(0x80000001,0,0)]
    elif name=='self_loop_reject':beats=ring(0)+[edge(0,0,0,0)]
    elif name=='endpoint_priority':
        beats=ring(0)+[edge(0,0,0),edge(0xffffffff,0,0),edge(1,1,0,0)]
    elif name=='ignored_keep0_payload':beats=[edge(0xffffffff,0xffffffff,low,1,0)]+ring(0)
    elif name=='first_tag_ownership':beats=ring(1)
    elif name=='directed_asymmetry':
        beats=ring(-1)+[edge(i,(i-1)%n,1) for i in range(n)]
    elif name=='equal_optimum_ties':
        assert n<=8
        beats=[edge(i,j,0) for i in range(n) for j in range(n) if i!=j]
    elif name in ('cheap_disjoint_subtours','subtours_infeasible'):
        assert n>=5
        graph={(0,1):-2,(1,0):-2}
        graph.update({(i,2+(i-2+1)%(n-2)):-2 for i in range(2,n)})
        if name=='cheap_disjoint_subtours':
            for i in range(n):graph.setdefault((i,(i+1)%n),1)
        beats=[edge(a,b,v) for (a,b),v in sorted(graph.items())]
    elif name=='sparse_equal_tours':
        assert n==12
        beats=ring(-1)+[edge(i,(i-1)%n,-1) for i in range(n)]
    else:raise ValueError(name)
    assert beats and len(beats)<=128
    tag=(0x80000001+17*ordinal)&((1<<tag_w)-1)
    for j,b in enumerate(beats):b[5]=int(j==len(beats)-1);b[6]=(tag+j)&((1<<tag_w)-1)
    assert all(low<=b[2]<=high and 0<=b[0]<(1<<32) and 0<=b[1]<(1<<32) for b in beats)
    return beats

def solve(beats,n):
    """Independent DFS over complete tours in this one fixed input graph."""
    graph={};error=0;tag=beats[0][6]
    for a,b,value,present,keep,last,_ in beats:
        if not keep:continue
        if a>=n or b>=n:error=1
        elif a==b:
            if error!=1:error=2
        elif not error:
            if present:graph[a,b]=value
            else:graph.pop((a,b),None)
    if error:return [[0,0,error,tag,0,0,0,1]],dict(error=error,tours_considered=0)
    best=None;visited={0};path=[0];tours=0
    def visit(cost):
        nonlocal best,tours
        node=path[-1]
        if len(path)==n:
            if (node,0) not in graph:return
            tours+=1;total=cost+graph[node,0]
            key=(total,tuple(reversed(path[1:])))
            if best is None or key<best[0]:best=(key,tuple(path)+(0,))
            return
        for target in range(1,n):
            if target not in visited and (node,target) in graph:
                visited.add(target);path.append(target)
                visit(cost+graph[node,target])
                path.pop();visited.remove(target)
    visit(0)
    if n==12:assert tours in (1,2), 'maximum fixed graphs must stay sparse certificates'
    if best is None:return [[0,0,0,tag,0,0,0,1]],dict(error=0,tours_considered=tours,feasible=False)
    key,tour=best;total=key[0]
    # Recheck the witness independently of the DFS accumulated sum.
    assert tour[0]==tour[-1]==0 and sorted(tour[:-1])==list(range(n))
    assert total==sum(graph[tour[i],tour[i+1]] for i in range(n))
    return [[1,1,0,tag,i,v,total,int(i==n)] for i,v in enumerate(tour)],dict(error=0,tours_considered=tours,feasible=True,tour=list(tour),cost=total)

ABORT_CODES={'partial_capture':1,'candidate_sum':2,'nonsingleton_commit':3,
             'trace_read':4,'held_nonlast':5,'held_final_future_offer':6}
def frame(case_id,name,p,kind=0,abort=0):
    beats=inputs(name,p['n'],p['w'],p['tag_w'],case_id)
    rows,certificate=solve(beats,p['n'])
    bound=1<<(p['w']+(p['n']-1).bit_length()-1)
    assert all(-bound<=r[6]<bound for r in rows)
    return dict(id=case_id,name=name,kind=kind,abort=abort,beats=beats,rows=rows,certificate=certificate)

def fixture(path,frames):
    lines=[str(len(frames))]
    for f in frames:
        lines.append(' '.join(map(str,[f['id'],f['kind'],f['abort'],len(f['beats']),len(f['rows'])])))
        lines.extend(' '.join(map(str,b)) for b in f['beats'])
        lines.extend(' '.join(map(str,r)) for r in f['rows'])
    path.write_text('\n'.join(lines)+'\n',encoding='ascii',newline='\n')

def main():
    if sys.flags.optimize:raise RuntimeError('optimized Python forbidden')
    assert len(sys.argv)==3 and sys.argv[1]=='--once'
    plan=read('CASE_PLAN.json');out=Path(sys.argv[2]).resolve()
    assert out.name=='generated' and out.parent.name=='preparation'
    assert not out.exists(), 'single preparation; preserve any failed partial output'
    out.mkdir(parents=True)
    records={};case_count=0;reset_jobs=0
    for index,p in enumerate(plan['profiles']):
        frames=[frame(index*100+i,name,p) for i,name in enumerate(p['cases'])]
        case_count+=len(frames);fixture(out/(p['name']+'_main.txt'),frames)
        records[p['name']]=dict(profile=p,main=frames)
        if p['resets']:
            reset=[]
            for j,name in enumerate(p['resets']):
                code=ABORT_CODES[name]
                reset.append(frame(1000+index*100+2*j,'negative_cycle',p,1,code))
                reset.append(frame(1001+index*100+2*j,'signed_extrema_cycle',p,2,0))
            reset_jobs+=len(p['resets']);fixture(out/(p['name']+'_reset.txt'),reset)
            records[p['name']]['reset']=reset
    assert case_count==plan['normal_cases']==40 and reset_jobs==plan['reset_jobs']==6
    document=dict(status='PREPARED_FIXED_CASES_ONLY',profiles=records,normal_cases=case_count,normal_replays=2*case_count,reset_jobs=reset_jobs,reference='Independent direct complete-tour DFS and witness cost/set certificate; no subset recurrence',input_cartesian_enumeration=False,hdl_launched=False,hardware='HW_UNVERIFIED')
    (out/'expected.json').write_text(json.dumps(document,indent=2)+'\n',encoding='utf-8',newline='\n')
    hashes={p.name:sha(p) for p in out.iterdir() if p.is_file()}
    (out/'MANIFEST.json').write_text(json.dumps(dict(files_sha256=hashes),indent=2)+'\n',encoding='utf-8',newline='\n')
    print(json.dumps(dict(status=document['status'],normal_cases=case_count,normal_replays=2*case_count,reset_jobs=reset_jobs,files=len(hashes))))

if __name__=='__main__':main()
