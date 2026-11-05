"""Fixed edge-subset enumeration certificates. No RTL DP or external packages."""
from pathlib import Path
import argparse,hashlib,json
P=Path(__file__).resolve().parent.parent
BASELINE='8f8e49a2cb9c3e48ecfaecb811f2d313058979b8'
PROFILES=[(1,1,1),(3,4,4),(6,8,8),(8,16,8),(12,32,32)]
PROBES={1:[0,1,7,9,13,14,15,16],3:[2,3,4,5,6,8,10,11],4:[10,12,14,16]}
def encoded(v):return (json.dumps(v,indent=2,sort_keys=True)+'\n').encode()
def digest(v):return hashlib.sha256(v).hexdigest()
def decision_key(mates):
    remaining=set(range(len(mates)));key=[]
    while remaining:
        v=min(remaining);remaining.remove(v);j=mates[v]
        key.append(j+1 if j>=0 else 0)
        if j>=0:remaining.remove(j)
    return tuple(key)
def optimum(n,edges):
    """Enumerate disjoint edge subsets in edge-list order, with no memoization.

    This does not implement the RTL's numeric-mask DP or per-vertex recurrence.
    A declarative decision key independently resolves equal-weight subsets.
    """
    choices=[(u,v,w) for (u,v),w in sorted(edges.items()) if w>0]
    best=0;winner=[-1]*n;winner_key=decision_key(winner);visited=0
    mates=[-1]*n
    def visit(start,used,total):
        nonlocal best,winner,winner_key,visited
        visited+=1
        if total>=best:
            key=decision_key(mates)
            if total>best or key<winner_key:
                best=total;winner=mates.copy();winner_key=key
        for e in range(start,len(choices)):
            u,v,w=choices[e];bits=(1<<u)|(1<<v)
            if not used&bits:
                mates[u]=v;mates[v]=u;visit(e+1,used|bits,total+w)
                mates[u]=mates[v]=-1
    visit(0,0,0)
    pairs=[(u,v) for u,v in enumerate(winner) if v>u]
    assert all(winner[v]==u and edges[u,v]>0 for u,v in pairs)
    assert sum(edges[u,v] for u,v in pairs)==best and len(pairs)<=n//2
    assert best<=n//2*max([0,*edges.values()])
    return dict(total=best,cardinality=len(pairs),mates=winner,
                decision_key=list(winner_key),enumerated_matchings=visited)
def resolve(n,tokens):
    edges={};error=0
    for q in tokens:
        if not q['keep']:continue
        u,v=q['u'],q['v']
        if u>=n or v>=n:error=1;continue
        if u==v:
            if error!=1:error=2
            continue
        pair=tuple(sorted((u,v)))
        if q['present']:edges[pair]=q['weight']
        else:edges.pop(pair,None)
    return edges,error
def frame(n,w,t,name,updates,identifier,version=0):
    tag=((0xa5+identifier*97)^(1<<(t-1)))&((1<<t)-1)
    def token(u,v,weight=0,present=1,keep=1):
        return dict(u=u,v=v,weight=weight,present=present,keep=keep,last=0,tag=0)
    body=[token(*q) for q in updates]
    if version:
        e,err=resolve(n,body)
        invalid=[q for q in body if q['keep'] and (q['u']>=n or q['v']>=n or q['u']==q['v'])]
        body=[token(v,u,weight) for (u,v),weight in reversed(sorted(e.items()))]
        # Duplicate assignments and reversed endpoint aliases retain the graph.
        body=body+body[:2]+invalid
    seq=[token(0xffffffff,0x80000000,-1,1,0),*body,
         token(0xffffffff,0xffffffff,0,0,0)]
    for i,q in enumerate(seq):q['tag']=tag if i==0 else (tag^(17+i))&((1<<t)-1)
    seq[-1]['last']=1;edges,err=resolve(n,seq)
    result=optimum(n,edges) if not err else dict(total=0,cardinality=0,mates=[-1]*n,decision_key=[],enumerated_matchings=0)
    sw=max(1,w-1+(max(1,n//2)-1).bit_length());assert result['total']<(1<<sw)
    return dict(id=identifier,name=name,version=version,tokens=seq,error=err,tag=tag,
                edges=[[u,v,c] for (u,v),c in sorted(edges.items())],**result)
def cases(n,w,t):
    lo=-(1<<(w-1));hi=(1<<(w-1))-1
    edge=lambda u,v,c:(u,v,max(lo,min(hi,c)),1,1)
    all_pairs=[(u,v) for u in range(n) for v in range(u+1,n)]
    specs=[('empty_masked_tag',[]),
           ('nonpositive_and_zero',[edge(u,v,-1 if (u+v)%2 else 0) for u,v in all_pairs]),
           ('odd_cycle_and_disconnected',[edge(u,(u+1)%3,hi) for u in range(3)] if n>=3 else []),
           ('dense_positive_ties',[edge(u,v,hi) for u,v in all_pairs]),
           ('signed_extrema',[edge(u,v,[lo,hi,0][(u*3+v)%3]) for u,v in all_pairs]),
           ('last_wins_reverse_remove',[(0,1,hi,1,1),(1,0,0,0,1),(1,0,max(0,hi-1),1,1)] if n>=2 else []),
           ('full_width_bad_endpoint',[(0x80000000,0,hi,0,1)]),
           ('deleted_self_loop',[(0,0,0,0,1)]),
           ('frame_endpoint_priority',[(0,0,hi,1,1),(0xffffffff,0,lo,1,1)])]
    if n>=4:specs.append(('greedy_trap',[edge(0,1,hi),edge(0,2,max(1,hi-1)),edge(1,3,max(1,hi-1))]))
    if n>=6:specs.append(('odd_blossom_bridge',[edge(0,1,5),edge(1,2,5),edge(2,0,5),edge(2,3,6),edge(3,4,7),edge(4,5,7),edge(5,3,7)]))
    out=[]
    for i,(name,updates) in enumerate(specs):
        a=frame(n,w,t,name,updates,2*i);b=frame(n,w,t,name,updates,2*i+1,1)
        # Tags deliberately differ by frame; matching identity must agree.
        assert all(a[k]==b[k] for k in ['error','total','cardinality','mates','edges'])
        if name=='dense_positive_ties':assert a['total']==(n//2)*hi
        if name=='odd_cycle_and_disconnected' and n>=3 and hi>0:
            assert a['total']==hi and a['mates'][:3]==[-1,2,1]
        if name=='greedy_trap' and hi>2:assert a['total']==2*(hi-1)
        out.extend([a,b])
    return out
def text(frames,n):
    lines=[str(len(frames))]
    for f in frames:
        lines.append(f"{f['id']} {len(f['tokens'])} {f['error']} {f['tag']} {f['total']} {f['cardinality']}")
        lines.append(' '.join(str(v) for v in f['mates']))
        lines.extend(' '.join(str(q[k]) for k in ['u','v','weight','present','keep','last','tag']) for q in f['tokens'])
    return ('\n'.join(lines)+'\n').encode()
def generate():
    files={};profiles=[];children=[];total_frames=total_rows=total_tokens=0
    def add(name,kind,argv,**more):children.append(dict(name=name,kind=kind,argv=argv,timeout_seconds=20,**more))
    add('stored_enumeration','oracle',['python','-B','sim/prepare.py','--verify'])
    add('tool_version','version',['iverilog','-V'])
    add('production_lint','lint',['iverilog','-g2012','-Wall','-tnull','-s','general_weighted_matching','rtl/general_weighted_matching.sv'])
    add('example_lint','lint',['iverilog','-g2012','-Wall','-tnull','-s','general_match8','rtl/general_weighted_matching.sv','example/general_match8.sv'])
    for i,(n,w,t) in enumerate(PROFILES):
        cs=cases(n,w,t);bound=(4*n+5)*((1<<n)-1)+2*n+4
        good=[(u,v,max(1,(1<<(w-1))-1),1,1) for u in range(n) for v in range(u+1,n)]
        fresh=frame(n,w,t,'fresh_complete_positive',good,100)
        bad=frame(n,w,t,'canceled_endpoint_error',[(0xffffffff,0,0,0,1)],101)
        probes=PROBES.get(i,[])
        p=dict(index=i,N=n,W=w,T=t,frames=len(cs),rows=sum(1 if c['error'] else n for c in cs),
               tokens=sum(len(c['tokens']) for c in cs),first_valid_bound=bound,probes=probes,
               commit_target=1024 if i==4 else 2,
               cycle_limit=(len(cs)+2)*(bound+40*n+1024))
        fixture=dict(profile=p,cases=cs,fresh=fresh,cancel=bad)
        files[f'fixtures/p{i}.json']=encoded(fixture);files[f'fixtures/p{i}.txt']=text(cs,n)
        files[f'fixtures/p{i}.fresh']=text([fresh],n);files[f'fixtures/p{i}.bad']=text([bad],n)
        files[f'fixtures/p{i}.probes']=(str(len(probes))+'\n'+'\n'.join(map(str,probes))+'\n').encode()
        profiles.append(p);total_frames+=len(cs);total_rows+=p['rows'];total_tokens+=p['tokens']
        binary=f'{{TMP}}/p{i}.vvp'
        add(f'p{i}_compile','compile',['iverilog','-g2012','-Wall','-s','tb',f'-Ptb.N={n}',f'-Ptb.W={w}',f'-Ptb.T={t}','-o',binary,'rtl/general_weighted_matching.sv','sim/tb.sv'],profile=i)
        add(f'p{i}_main','simulation',['vvp',binary,f'+PROFILE={i}','+MODE=0'],profile=i,mode=0)
        if probes:add(f'p{i}_reset','simulation',['vvp',binary,f'+PROFILE={i}','+MODE=1'],profile=i,mode=1)
    for key,value in [('NUM_NODES',0),('NUM_NODES',13),('WEIGHT_W',0),('WEIGHT_W',33),('TAG_W',0),('TAG_W',33)]:
        add(f'reject_{key}_{value}','reject',['iverilog','-g2012','-tnull','-s','general_weighted_matching',f'-Pgeneral_weighted_matching.{key}={value}','rtl/general_weighted_matching.sv'])
    assert len(children)==23 and sum(c['kind']=='simulation' for c in children)==8
    plan=dict(schema=1,baseline=BASELINE,profiles=profiles,children=children,
              totals=dict(main_frames=total_frames,main_rows=total_rows,main_tokens=total_tokens,resets=sum(map(len,PROBES.values()))),
              oracle='Uncached enumeration of all disjoint positive edge subsets; lexicographic decision-key tie certificate; fixed hand upper bounds.',
              stimulus='Fixed named cases only, two complete graph replays; no Cartesian input matrices, random search or inherited tests.',
              first_failure_stops=True,automatic_retry=False,timeout_seconds=20,hardware='HW_UNVERIFIED')
    files['TEST_PLAN.json']=encoded(plan);return files
def main():
    a=argparse.ArgumentParser();g=a.add_mutually_exclusive_group(required=True);g.add_argument('--prepare',action='store_true');g.add_argument('--verify',action='store_true');x=a.parse_args()
    values=generate()
    if x.prepare:
        assert not (P/'fixtures').exists() and not (P/'TEST_PLAN.json').exists()
        for name,raw in values.items():
            p=P/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(raw)
        print('PREPARED fixed edge-subset certificates profiles=5')
    else:
        assert all((P/name).read_bytes()==raw for name,raw in values.items())
        actual={p.relative_to(P).as_posix() for p in (P/'fixtures').iterdir() if p.is_file()}
        assert actual=={n for n in values if n.startswith('fixtures/')}
        print('PASS fixed edge-subset certificates profiles=5')
if __name__=='__main__':main()
