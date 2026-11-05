"""Stored-certificate and raw chronology checks. No model import or search."""
# SPDX-License-Identifier: Apache-2.0
import hashlib,json,re,sys
from pathlib import Path
if sys.flags.optimize:raise RuntimeError('optimized Python forbidden')

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def certificate(case,edges,cost,count,vertices,complete=True):
    """Check the supplied tree only; never seek a better tree or DP state."""
    assert edges==sorted(edges) and len({(u,v) for u,v,w in edges})==len(edges)
    n=case['n'];graph={(u,v):w for u,v,w in case['edges']};parent=list(range(n))
    def find(v):
        while parent[v]!=v:v=parent[v]
        return v
    used=0;total=0
    for u,v,w in edges:
        assert 0<=u<v<n and graph.get((u,v))==w and w>0
        a,b=find(u),find(v);assert a!=b;parent[a]=b
        used|=(1<<u)|(1<<v);total+=w
    assert 0<=count<=n-1 and 0<=vertices<(1<<n)
    assert len(edges)<=count and total<=cost
    if complete:
        if len(case['terminals'])==1:
            assert not edges;used=case['terminal_mask']
        assert len(edges)==count and total==cost and used==vertices
        terminal=case['terminals'][0];root=find(terminal)
        assert all(find(v)==root for v in range(n) if (used|case['terminal_mask'])&(1<<v))

def verify_prepared(folder,table,plan):
    manifest=json.loads((folder/'MANIFEST.json').read_bytes())
    assert manifest['status']=='FIXED23_PREPARED_ONCE' and manifest['model_calls']==23
    expected=manifest['files_sha256']
    actual={p.relative_to(folder).as_posix():sha(p) for p in folder.rglob('*') if p.is_file() and p.name!='MANIFEST.json'}
    assert actual==expected and len(actual)==13
    data=json.loads((folder/'DATA.json').read_bytes())
    assert data['schema']=='steiner-fixed23-v1' and data['model_calls']==23
    assert data['materialize_calls']==23 and data['witness_checks']==14
    assert data['profiles']==table['profiles'] and len(data['cases'])==23 and len(data['jobs'])==12
    assert data['case_table_sha256']==plan['case_table_sha256']
    assert data['preparation_plan_sha256']==hashlib.sha256((folder.parents[1]/'PREPARATION_PLAN.json').read_bytes()).hexdigest()
    profiles={p['id']:p for p in table['profiles']}
    for index,(c,recipe) in enumerate(zip(data['cases'],table['cases'],strict=True)):
        p=profiles[c['profile']];n=p['N'];maximum=(1<<p['W'])-1
        assert c['id']==index and c['name']==recipe['name'] and c['profile']==recipe['profile']
        assert c['n']==n and c['terminals']==recipe['terminals']
        assert c['terminal_mask']==sum(1<<v for v in c['terminals'])
        graph={(u,v):w for u,v,w in c['edges']}
        assert len(graph)==len(c['edges']) and all(0<=u<v<n and 0<=w<=maximum for (u,v),w in graph.items())
        assert len(c['inputs'])==n*(n-1)//2
        for beat,(u,v) in zip(c['inputs'],((u,v) for u in range(n) for v in range(u+1,n)),strict=True):
            present,w,last=beat
            assert present==int((u,v) in graph) and w==graph.get((u,v),maximum if recipe.get('absent_weight')=='MAX' else 0)
            edge_index=u*(2*n-u-1)//2+v-u-1
            mode=recipe.get('last_mode','correct')
            assert last==int((edge_index==len(c['inputs'])-1 and mode!='missing') or (mode=='early_and_final' and edge_index==0))
        target=c['target'];assert target['error']==recipe.get('error',0)
        assert target['feasible']==(not recipe.get('error') and not recipe.get('infeasible'))
        assert target['cost']==recipe.get('cost',0)
        if target['feasible']:
            certificate(c,[tuple(e) for e in target['edges']],target['cost'],len(target['edges']),c['reference_witness_vertices'])
        else:assert target['cost']==0 and not target['edges'] and c['reference_witness_vertices']==0
    byname={c['name']:c for c in data['cases']}
    for ji,j in enumerate(data['jobs']):
        spec=(table['normal_jobs']+table['reset_jobs'])[ji]
        assert j['name']==spec['name'] and j['profile']==spec['profile']
        if ji<6:
            ids=[byname[n]['id'] for n in spec['cases']];mask=(1<<profiles[j['profile']]['T'])-1
            frames=[dict(case=c,tag=(i+1)&mask) for i,c in enumerate(ids)]
            assert j['reset']==-1 and j['future']==int('future_offer' in spec)
        else:
            frames=[dict(case=byname[spec['owner']]['id'],tag=85),dict(case=byname[spec['fresh']]['id'],tag=170)]
            assert j['reset']==ji-6 and not j['future']
        assert j['frames']==frames
        lines=[str(len(frames))]
        for frame in frames:
            c=data['cases'][frame['case']]
            lines.append(f"{c['id']} {frame['tag']} {c['terminal_mask']}")
            lines.extend(' '.join(map(str,b)) for b in c['inputs'])
        lines.append('-99')
        assert (folder/(j['name']+'.txt')).read_bytes()==('\n'.join(lines)+'\n').encode('ascii')
    assert plan['model_calls']==23
    return data

def audit(raw,data,job):
    lines=raw.decode('ascii').splitlines();assert lines and lines[-1].startswith('END ')
    # Caller removes only the exact Icarus $finish suffix, preserving raw bytes.
    p=next(p for p in data['profiles'] if p['id']==job['profile'])
    assert lines[0].split()==['BEGIN',job['name'],str(p['N']),str(p['K']),str(p['W']),str(p['T']),str(job['reset']),str(len(job['frames']))]
    cases=data['cases'];fi=-1;active=None;current=None;inputs=[];edges=[]
    previous_pin=None;previous_output=None;last_cycle=0;resets=[];cut=None;offered=None;nextin=None
    hold_in=hold_out=hand_out=held_edges=held_summaries=0;completed=0;summaries=0;metadata=None;cancelled=False
    pin_events=[];summary_cycle=None
    event_cycles=set()
    for line_index,line in enumerate(lines[1:],1):
        tokens=line.split();kind=tokens[0];v=list(map(int,tokens[1:]))
        cycle=v[0];assert cycle>=last_cycle;last_cycle=cycle
        if kind=='FRAME':
            assert len(v)==4 and (fi<0 or completed+int(cancelled)==fi+1)
            fi+=1;assert fi<len(job['frames']);frame=job['frames'][fi];current=cases[frame['case']]
            assert v[1:]==[current['id'],frame['tag'],current['terminal_mask']]
            active=current['id'];inputs=[];edges=[];metadata=None;cancelled=False;summary_cycle=None
        elif kind=='RST':
            assert len(v)==2 and ('RST',cycle) not in event_cycles
            assert ('PIN',cycle) not in event_cycles and ('POUT',cycle) not in event_cycles
            event_cycles.add(('RST',cycle));resets.append(tuple(v));previous_pin=None;previous_output=None
        elif kind=='PIN':
            assert len(v)==9 and current is not None
            assert ('PIN',cycle) not in event_cycles and ('RST',cycle) not in event_cycles
            event_cycles.add(('PIN',cycle))
            _,fid,index,present,w,last,terms,tag,ready=v
            payload=v[1:8];assert ready in (0,1)
            if previous_pin is not None:assert payload==previous_pin
            previous_pin=payload if not ready else None
            if not ready:hold_in+=1
            if fid==-2:
                assert job['future'] and offered is not None and fi==len(job['frames'])-1 and index==0
                assert [present,w,last]==current['inputs'][0]
                assert terms==current['terminal_mask'] and tag==(0x5a&((1<<p['T'])-1))
                pin_events.append((cycle,ready))
            else:
                assert fid==active and index==len(inputs) and [present,w,last]==current['inputs'][index]
                tm=(1<<p['N'])-1;tg=(1<<p['T'])-1
                frame=job['frames'][fi]
                assert terms==(current['terminal_mask'] if index==0 else current['terminal_mask']^tm)
                assert tag==(frame['tag'] if index==0 else frame['tag']^tg)
                if ready:inputs.append([present,w,last])
        elif kind=='POUT':
            assert len(v)==14 and current is not None
            assert ('POUT',cycle) not in event_cycles and ('RST',cycle) not in event_cycles
            event_cycles.add(('POUT',cycle))
            _,fid,ready,summary,u,wv,weight,cost,count,vertices,terms,feasible,error,tag=v
            assert fid==active and ready in (0,1) and summary in (0,1)
            payload=v[3:];assert len(inputs)==len(current['inputs'])
            if previous_output is not None:assert payload==previous_output
            previous_output=payload if not ready else None
            if not ready:
                hold_out+=1
                if summary:held_summaries+=1
                else:held_edges+=1
            target=current['target']
            assert terms==current['terminal_mask'] and tag==job['frames'][fi]['tag']
            assert cost==target['cost'] and feasible==int(target['feasible']) and error==target['error']
            meta=(cost,count,vertices,terms,feasible,error,tag)
            if metadata is not None:assert meta==metadata
            metadata=meta
            if summary:
                assert u==wv==weight==0
                if target['feasible']:certificate(current,edges,cost,count,vertices)
                else:assert not edges and count==vertices==0
                if ready:completed+=1;summaries+=1;summary_cycle=cycle
            else:
                assert feasible and not error and summary_cycle is None
                candidate=edges+[(u,wv,weight)]
                certificate(current,candidate,cost,count,vertices,complete=False)
                if ready:edges=candidate
            if ready:hand_out+=1
        elif kind=='CUT':
            assert len(v)==8 and cut is None and job['reset']>=0 and fi==0
            _,rid,state,ic,mask,src,dst,pending=v
            assert rid==job['reset'] and summaries==0
            if rid==0:assert state==0 and ic==3 and len(inputs)==3
            elif rid==1:assert state==11 and mask==3
            elif rid==2:assert state==23 and (mask,src,dst)==(1,1,3)
            elif rid==3:assert state==32 and pending>0
            elif rid==4:assert state==43 and previous_output is not None and previous_output[0]==0
            else:assert state==45 and previous_output is not None and previous_output[0]==1
            cut=v;cancelled=True
        elif kind=='OFFER':
            assert len(v)==1 and job['future'] and offered is None;offered=cycle
        elif kind=='NEXTIN':
            assert len(v)==1 and job['future'] and nextin is None
            assert completed==len(job['frames']) and summary_cycle<cycle
            assert pin_events and pin_events[-1]==(cycle,1)
            assert all(not ready for c,ready in pin_events[:-1]);nextin=cycle
        elif kind=='END':
            assert len(v)==4 and line_index==len(lines)-1
            assert fi+1==len(job['frames'])
            assert completed==len(job['frames'])-int(job['reset']>=0)
            assert v[1]==(1 if job['reset']>=0 else 2 if job['future'] else 0)
            assert v[2]==held_edges and v[3]==held_summaries and held_summaries>0
        else:raise AssertionError(('unknown raw line',line))
    groups=[]
    for cycle,phase in resets:
        if not groups or phase!=groups[-1][0] or cycle!=groups[-1][1][-1]+1:groups.append((phase,[cycle]))
        else:groups[-1][1].append(cycle)
    expected_phases=[0]+([1] if job['reset']>=0 else [2] if job['future'] else [])
    assert [phase for phase,cycles in groups]==expected_phases and all(len(cycles)==3 for phase,cycles in groups)
    if job['reset']>=0:assert cut is not None and groups[1][1][0]==cut[0]+1
    else:assert cut is None
    if job['future']:
        assert offered is not None and nextin is not None and offered<summary_cycle<nextin
        assert groups[-1][1][0]==nextin+1
    else:assert offered is None and nextin is None
    assert previous_pin is None and previous_output is None
    return dict(job=job['name'],completed=completed,input_holds=hold_in,output_holds=hold_out,
                output_handshakes=hand_out,reset_edges=len(resets),cycles=last_cycle)

def normalized_output(raw):
    lines=raw.decode('ascii').splitlines()
    assert len(lines)>=3 and re.fullmatch(r'sim/tb_steiner\.sv:\d+: \$finish called at \d+ \(1ps\)',lines[-1])
    return ('\n'.join(lines[:-1])+'\n').encode('ascii')

if __name__=='__main__':
    p=Path(__file__).resolve().parent
    table=json.loads((p/'CASE_TABLE.json').read_bytes());plan=json.loads((p/'PREPARATION_PLAN.json').read_bytes())
    verify_prepared(p/'preparation/generated',table,plan)
    print('PASS STORED_ONLY_CERTIFICATES_23')
