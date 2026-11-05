"""Independent threshold-set/Fraction specification. Preparation only.

No imports from RTL helpers, no sorted activation, union/find, ancestor-walk
simulation, or numerical calls during HDL validation.
"""
from fractions import Fraction


def pixels(recipe: dict, width: int, height: int) -> list[int]:
    name=recipe['kind'];n=width*height
    if name=='literal':
        result=list(recipe['values'])
    elif name=='constant':result=[recipe['value']]*n
    elif name=='ramp':result=[(recipe.get('offset',0)+recipe.get('step',1)*i)%256 for i in range(n)]
    elif name=='reverse':result=[255-i for i in range(n)]
    elif name=='checker':result=[255*((x+y)%2) for y in range(height) for x in range(width)]
    elif name=='rings':
        result=[recipe['step']*min(x,y,width-1-x,height-1-y) for y in range(height) for x in range(width)]
    elif name=='affine_bytes':result=[(recipe['a']*i+recipe.get('row',0)*(i//width)+recipe['b'])%256 for i in range(n)]
    elif name=='last_bright':result=[0]*(n-1)+[255]
    elif name=='area4':result=[255 if 2<=x<=3 and 2<=y<=3 else 0 for y in range(height) for x in range(width)]
    elif name=='tie124':result=[28,29,30,28]+[0]*(n-4)
    elif name=='two_peaks':
        result=[0]*n
        for y in range(1,height-1):
            for x in range(1,width-1):result[y*width+x]=40
        result[2*width+2]=200;result[2*width+width-3]=160
        result[2*width+3]=80
    else:raise ValueError('unknown frozen recipe '+name)
    if len(result)!=n or any(type(v) is not int or not 0<=v<=255 for v in result):raise ValueError('recipe domain')
    return result


def compute(values: list[int],profile: dict,case: dict) -> dict:
    w,h,k=profile['width'],profile['height'],profile['connectivity'];n=w*h
    c=case['config'];bright=c['bright'];delta=c['delta'];p,q=c['p'],c['q']
    error=case.get('marker_error',0)
    if delta==0 or q==0 or not 1<=c['min_area']<=c['max_area']<=n:error|=4
    tag=case['tag']&((1<<profile['tag_w'])-1)
    def record(i,parent=0,level=0,area=0,num=0,den=0,canonical=0,selected=0):
        return [i,parent,level,area,num,den,canonical,selected,error,tag,int(i==0),int(i%w==w-1),int(i==n-1)]
    if error:return dict(records=[record(i) for i in range(n)],nodes=[],root=None,edges=[],error=error)
    g=[v if bright else 255-v for v in values]
    offsets=[(-1,0),(1,0),(0,-1),(0,1)]
    if k==8:offsets += [(-1,-1),(-1,1),(1,-1),(1,1)]
    nodes={}
    # Discover all connected sets independently at every present threshold.
    for level in sorted(set(g)):
        unseen={i for i,v in enumerate(g) if v>=level}
        while unseen:
            seed=min(unseen);unseen.remove(seed);component={seed};todo=[seed]
            while todo:
                v=todo.pop();x,y=v%w,v//w
                for dx,dy in offsets:
                    xx,yy=x+dx,y+dy
                    if 0<=xx<w and 0<=yy<h:
                        u=yy*w+xx
                        if u in unseen:unseen.remove(u);component.add(u);todo.append(u)
            same={i for i in component if g[i]==level}
            if same:
                representative=min(same)
                nodes[representative]=dict(level=level,members=frozenset(component),area=len(component))
    root=next(i for i,node in nodes.items() if node['area']==n)
    for i,node in nodes.items():
        supersets=[j for j,other in nodes.items() if node['members']<other['members']]
        parent=min(supersets,key=lambda j:nodes[j]['area']) if supersets else i
        eligible=[j for j,other in nodes.items() if node['members']<=other['members'] and
                  node['level']-delta<=other['level']<=node['level']]
        top=max(eligible,key=lambda j:nodes[j]['area'])
        node.update(parent=parent,top=top,num=nodes[top]['area']-node['area'])
        node['variation']=Fraction(node['num'],node['area'])
    losers=set();edges=[]
    for i,node in nodes.items():
        j=node['parent']
        if i!=j and node['level']-nodes[j]['level']==1:
            loser=j if node['variation']<nodes[j]['variation'] else i
            losers.add(loser);edges.append([i,j,loser,int(node['variation']==nodes[j]['variation'])])
    records=[record(i) for i in range(n)]
    proofs=[]
    for i,node in sorted(nodes.items()):
        stable=i not in losers
        selected=(stable and i!=root and c['min_area']<=node['area']<=c['max_area'] and node['variation']<Fraction(p,q))
        records[i]=record(i,node['parent'],values[i],node['area'],node['num'],node['area'],1,int(selected))
        proofs.append(dict(seed=i,level_g=node['level'],area=node['area'],parent=node['parent'],
            top=node['top'],num=node['num'],stable=int(stable),selected=int(selected),
            threshold_equal=int(node['variation']==Fraction(p,q))))
    assert len(nodes)>=1 and records[root][3]==n and records[root][7]==0
    assert all(not r[7] or (r[6] and r[3]>0 and r[4]*q<p*r[3]) for r in records)
    return dict(records=records,nodes=proofs,root=root,edges=edges,error=0)


def boundary_certificates(results: dict,table: dict) -> dict:
    """Fixed obligations only; never search or add cases to obtain a witness."""
    ties=results['P3-D02']
    tie_edges=[e for e in ties['edges'] if e[3] and e[2]==e[0]]
    strict=results['P3-D03'];strict_nodes=[n for n in strict['nodes'] if n['seed']!=strict['root'] and n['stable'] and n['threshold_equal']]
    gap=results['P1-L03'];gap_nodes={n['seed']:n for n in gap['nodes']}
    gap_witness=[n for n in gap['nodes'] if n['parent']!=n['seed'] and
        n['level_g']-gap_nodes[n['parent']]['level_g']>1 and n['top']!=n['seed']]
    area=results['P3-D04'];area_witness=[n for n in area['nodes'] if n['area']==4 and n['selected']]
    maximum=results['P4-X01']
    obligations={'C_ROOT':all(not r['records'][r['root']][7] for r in results.values() if r['root'] is not None),
        'C_TIE_PARENT':bool(tie_edges),'C_STRICT_EQUAL_REJECT':bool(strict_nodes) and all(not n['selected'] for n in strict_nodes),
        'C_GRAY_GAP':bool(gap_witness),'C_AREA_EQUAL':bool(area_witness),
        'C_AREA_256':maximum['records'][maximum['root']][3]==256,
        'C_PRODUCT_WIDTH':all(n['num']<=255 and n['area']<=256 for r in results.values() for n in r['nodes'])}
    if not all(obligations.values()):raise ValueError('fixed boundary certificate missing: '+repr(obligations))
    return dict(status='FIXED_CERTIFICATES_PASS',obligations=obligations,tie_edges=tie_edges,
        strict_nodes=strict_nodes,gap_witness=gap_witness,area_witness=area_witness,
        no_search=True,no_additional_cases=True)
