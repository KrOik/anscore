"""Check actual finite streams against prepared immutable tuples; no oracle."""
from pathlib import Path
import hashlib,json,re,sys
if sys.flags.optimize:raise RuntimeError('optimized Python forbidden')

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def verify_prepared(directory,case_plan):
    manifest=json.loads((directory/'MANIFEST.json').read_bytes())['files_sha256']
    names={'expected.json'}|{p['name']+'_main.txt' for p in case_plan['profiles']}|{p['name']+'_reset.txt' for p in case_plan['profiles'] if p['resets']}
    assert set(manifest)==names and all(Path(n).name==n for n in manifest)
    assert set(p.name for p in directory.iterdir() if p.is_file())=={Path(n).name for n in manifest}|{'MANIFEST.json'}
    for n,h in manifest.items():assert sha(directory/Path(n).name)==h
    expected=json.loads((directory/'expected.json').read_bytes())
    assert expected['normal_cases']==40 and expected['normal_replays']==80 and expected['reset_jobs']==6
    assert expected['profiles'].keys()=={p['name'] for p in case_plan['profiles']}
    for p in case_plan['profiles']:
        data=expected['profiles'][p['name']];assert data['profile']==p
        assert [f['name'] for f in data['main']]==p['cases']
        for kind in ['main','reset']:
            if kind not in data:assert kind=='reset' and not p['resets'];continue
            frames=data[kind];flat=[len(frames)]
            for f in frames:
                flat.extend([f['id'],f['kind'],f['abort'],len(f['beats']),len(f['rows'])])
                flat.extend(v for row in f['beats'] for v in row)
                flat.extend(v for row in f['rows'] for v in row)
            actual=list(map(int,(directory/(p['name']+'_'+kind+'.txt')).read_text('ascii').split()))
            assert actual==flat, 'fixture/expected exact ordered integer binding'
    return expected

def audit(stdout,profile,frames,mode,reset_suite):
    lines=stdout.decode('utf-8').splitlines();events=[];finish=[]
    widths={'IN':9,'REC':9,'ABORTREC':9,'PROBE':16,'RESETEDGE':2,'RESETDONE':2,'OFFER':3,'FRAME':5,'PASS':3}
    for line in lines:
        token=line.split(' ',1)[0]
        if token in widths:
            values=line.split()[1:]
            assert len(values)==widths[token] and all(re.fullmatch(r'-?\d+',v) for v in values),line
            events.append((token,tuple(map(int,values))))
        else:
            assert re.fullmatch(r'sim/tb_exact_directed_hamiltonian_cycle.sv:\d+: \$finish called at \d+ \(1ps\)',line),line
            finish.append(line)
    assert len(finish)==1 and lines[-1]==finish[0] and events[-1]==('PASS',(mode,int(reset_suite),len(frames)))
    assert sum(t=='PASS' for t,v in events)==1
    n=profile['n'];input_expected=[];output_expected=[];abort_expected=[]
    frame_expected=[];probes_expected=[];reset_expected=[];done_expected=[];offers_expected=[]
    for i,f in enumerate(frames):
        code=f['abort'];accepted=1 if code==1 else len(f['beats'])
        input_expected.extend((f['id'],j,*b) for j,b in enumerate(f['beats'][:accepted]))
        if code:
            prefix=f['rows'][:-1] if code==6 else []
            abort_expected.extend((f['id'],*r) for r in prefix)
            probes_expected.append((f,accepted,len(prefix)))
            reset_expected.extend((f['id'],e) for e in range(3))
            done_expected.append((f['id'],frames[i+1]['id']))
        else:
            output_expected.extend((f['id'],*r) for r in f['rows'])
            frame_expected.append((f['id'],len(f['beats']),len(f['rows'])))
        if code==6 or (code==0 and mode==1 and i+1<len(frames)):
            offers_expected.append((f['id'],frames[i+1]['id']))
    assert [v for t,v in events if t=='IN']==input_expected
    assert [v for t,v in events if t=='REC']==output_expected
    assert [v for t,v in events if t=='ABORTREC']==abort_expected
    assert [v for t,v in events if t=='RESETEDGE']==reset_expected
    assert [v for t,v in events if t=='RESETDONE']==done_expected
    offers=[v for t,v in events if t=='OFFER'];assert [v[:2] for v in offers]==offers_expected
    assert all(v[2]>=0 for v in offers)
    actual_frames=[v for t,v in events if t=='FRAME']
    assert [v[:3] for v in actual_frames]==frame_expected
    for case_id,ins,outs,cycles,held in actual_frames:
        k=n-1;bound=n*n+ins+4*k*k*((1<<k)-1)+8*k+n+16+10*ins+10*(n+1)+100
        assert 0<cycles<=bound and 0<=held<=cycles
        if mode==1:assert held>=3
    probes=[v for t,v in events if t=='PROBE'];assert len(probes)==len(probes_expected)
    for v,(f,accepted,prefix) in zip(probes,probes_expected,strict=True):
        case_id,code,ii,oo,state,mvalid,mready,svalid,sready,mask,rem,node,scan,best,candidate,total=v
        assert (case_id,code,ii,oo)==(f['id'],f['abort'],accepted,prefix)
        assert state=={1:1,2:7,3:9,4:14,5:16,6:16}[code]
        assert all(x in (0,1) for x in [mvalid,mready,svalid,sready,best,candidate])
        if code==1:assert ii==1 and mvalid==0 and sready==1
        elif code in (2,3):
            assert 0<node<n and rem==mask&~(1<<(node-1)) and rem!=0 and mvalid==sready==0
            if code==2:assert 0<scan<n and rem&(1<<(scan-1))
            else:assert best==1
        elif code==4:assert mask==(1<<(n-1))-1 and 0<node<n and mvalid==sready==0
        elif code==5:assert oo==0 and mvalid==1 and mready==sready==0
        elif code==6:assert oo==n and mvalid==svalid==1 and mready==sready==0
    # Require semantic event order, not only equality of separately collected sets.
    positions={}
    for index,(token,v) in enumerate(events):
        if token!='PASS':positions.setdefault(v[0],[]).append((index,token,v))
    for f in frames:
        sequence=positions[f['id']];ins=[i for i,t,v in sequence if t=='IN']
        outs=[i for i,t,v in sequence if t in ('REC','ABORTREC')]
        if outs:assert max(ins)<min(outs)
        if f['abort']:
            probe=[i for i,t,v in sequence if t=='PROBE'];edges=[i for i,t,v in sequence if t=='RESETEDGE']
            assert len(probe)==1 and len(edges)==3 and max(ins)<probe[0]<min(edges)
            if outs:assert max(outs)<probe[0]
            fresh=positions[frames[frames.index(f)+1]['id']]
            assert max(edges)<min(i for i,t,v in fresh if t=='IN')
            assert max(i for i,t,v in fresh if t=='FRAME')<next(i for i,t,v in sequence if t=='RESETDONE')
        else:
            end=next(i for i,t,v in sequence if t=='FRAME');assert outs and max(outs)<end
        offered=[i for i,t,v in sequence if t=='OFFER']
        if offered:
            terminal=next(i for i,t,v in sequence if t==('PROBE' if f['abort'] else 'FRAME'))
            assert len(offered)==1 and outs and max(ins)<offered[0]<min(outs)<terminal
    for left,right in zip(frames,frames[1:]):
        before=positions[left['id']];after=positions[right['id']]
        boundary=max(i for i,t,v in before if t==('RESETEDGE' if left['abort'] else 'FRAME'))
        assert boundary<min(i for i,t,v in after if t=='IN'), 'one owner retires or resets before another is accepted'
    for i,f in enumerate(frames):
        if f['abort']:
            done=next(j for j,t,v in positions[f['id']] if t=='RESETDONE')
            if i+2<len(frames):assert done<min(j for j,t,v in positions[frames[i+2]['id']] if t=='IN')
    return dict(status='EXACT_ORDERED_RAW_PASS',profile=profile['name'],mode=mode,reset=bool(reset_suite),records=len(output_expected),aborted_prefix_records=len(abort_expected),accepted_tokens=len(input_expected),frames=len(frame_expected),reset_jobs=len(probes_expected),offers=len(offers),raw_lines=len(lines))
