"""Independent upper-level-set oracle; one frozen bounded owner matrix."""
import argparse
from collections import Counter
import hashlib
import itertools
import json
import os
from pathlib import Path
import random
import subprocess
import tempfile
import time

ROOT=Path(__file__).resolve().parent
BASELINE='ed4eda4fe213da6f6fec793ef911daaabfeba2cc'
PROFILES=[(1,1,1,4,1),(1,7,8,8,3),(7,1,3,4,8),(2,2,2,4,8),(2,2,2,8,8),
          (3,3,1,4,8),(3,3,1,8,8),(8,8,8,4,8),(16,16,8,4,32),(16,16,8,8,32)]
NEGATIVES=[('w0',0,8,8,4,8),('w17',17,8,8,4,8),('h0',8,0,8,4,8),('h17',8,17,8,4,8),
           ('b0',8,8,0,4,8),('b9',8,8,9,4,8),('k3',8,8,8,3,8),('k9',8,8,8,9,8),
           ('t0',8,8,8,4,0),('t33',8,8,8,4,33)]
def sha(raw):return hashlib.sha256(raw).hexdigest()
def save_json(path,value):path.write_bytes((json.dumps(value,indent=2)+'\n').encode())
def source_hashes():
    return {p.relative_to(ROOT).as_posix():sha(p.read_bytes()) for p in sorted(ROOT.rglob('*'))
            if p.is_file() and p.name not in ['TEST_PLAN.json','verification.json'] and '__pycache__' not in p.parts}
def reset_ids(w,h):
    n=w*h
    return [i for i in range(46) if not (n==1 and i in [16,17,18,19,20,21,22,38,39,42])
            and not (i==40 and h==1) and not (i==41 and (w<3 or h<2))]
def degree(w,h,k):return 2*h*(w-1)+2*w*(h-1)+(4*(w-1)*(h-1) if k==8 else 0)
def neighbors(p,w,h,k):
    x,y=p%w,p//w
    for dx,dy in [(-1,0),(1,0),(0,-1),(0,1)]+([(-1,-1),(1,-1),(-1,1),(1,1)] if k==8 else []):
        if 0<=x+dx<w and 0<=y+dy<h:yield (y+dy)*w+x+dx
def oracle(pixels,w,h,k):
    """Enumerate upper-level connected sets and their strict inclusion parents.

    No sorted activation, union/find, pointer compression or hardware schedule.
    """
    n=w*h;nodes=[];owners={};level_sets={}
    for level in sorted(set(pixels)):
        remaining={p for p,v in enumerate(pixels) if v>=level};components=[]
        while remaining:
            seed=min(remaining);remaining.remove(seed);component={seed};frontier=[seed]
            while frontier:
                for q in neighbors(frontier.pop(),w,h,k):
                    if q in remaining:remaining.remove(q);component.add(q);frontier.append(q)
            mask=sum(1<<p for p in component);components.append(mask)
            representatives=[p for p in component if pixels[p]==level]
            if representatives:
                representative=min(representatives)
                for p in representatives:owners[p]=representative
                nodes.append(dict(level=level,index=representative,mask=mask,area=len(component)))
        level_sets[level]=set(components)
    assert len(owners)==n and 1<=len(nodes)<=n
    node_map={a['index']:a for a in nodes}
    for a in nodes:
        supersets=[b for b in nodes if b['level']<a['level'] and (a['mask']&b['mask'])==a['mask']]
        a['parent']=max(supersets,key=lambda b:b['level'])['index'] if supersets else a['index']
        assert a['area']==a['mask'].bit_count()
        assert a['index']==min(p for p,v in enumerate(pixels) if v==a['level'] and (a['mask']>>p)&1)
    roots=[a for a in nodes if a['parent']==a['index']]
    assert len(roots)==1 and roots[0]['area']==n and roots[0]['level']==min(pixels)
    # Every threshold partition is represented by exactly its enclosing tree nodes.
    for level,sets in level_sets.items():
        reconstructed={a['mask'] for a in nodes if a['level']>=level and
                       (a['parent']==a['index'] or node_map[a['parent']]['level']<level)}
        assert reconstructed==sets
    result=[]
    for p,v in enumerate(pixels):
        canonical=p==owners[p];a=node_map[owners[p]]
        result.append((a['parent'] if canonical else owners[p],v,int(canonical),a['area'] if canonical else 0))
    assert all(0<=a[0]<n and pixels[a[0]]<=pixels[p] for p,a in enumerate(result))
    return result,len(nodes)
def images(w,h,b,k):
    n=w*h;maximum=(1<<b)-1;rng=random.Random(0xB21000+w*101+h*17+b*3+k)
    ramp=[p&maximum for p in range(n)];reverse=list(reversed(ramp))
    checker=[maximum if (p%w+p//w)%2 else 0 for p in range(n)]
    nested=[(min(p%w,w-1-p%w,p//w,h-1-p//w)*max(1,maximum//3))&maximum for p in range(n)]
    if n==256:
        nested=[85*(min(p%w,w-1-p%w,p//w,h-1-p//w)//2) for p in range(n)]
        random_image=[rng.randrange(maximum+1) for _ in range(n)]
        return [(a,0) for a in [[maximum]*n,ramp,reverse,checker,nested,random_image]]+[(ramp,1),(random_image,3)]
    patterns=[[0]*n,[maximum]*n,ramp,reverse,checker,nested,
              [maximum if p%w==p//w else 0 for p in range(n)],
              [maximum if p==n//2 else 0 for p in range(n)],
              [maximum if p<2 else 0 for p in range(n)],
              [maximum if p%w==0 or p//w==h-1 else maximum//2 for p in range(n)],
              [rng.randrange(maximum+1) for _ in range(n)],[rng.randrange(maximum+1) for _ in range(n)]]
    out=[(a,0) for a in patterns]+[(ramp,1),(reverse,1),(checker,2),(nested,3)]
    if (w,h,b)==(2,2,2):out += [(list(a),0) for a in itertools.product(range(4),repeat=4)]
    if (w,h,b)==(3,3,1):out += [([(mask>>p)&1 for p in range(n)],0) for mask in range(512)]
    return out
def pack(fields):
    value=0
    for a,b in fields:value=(value<<b)|(a&((1<<b)-1))
    return value
def freeze():
    assert not (ROOT/'TEST_PLAN.json').exists() and not (ROOT/'verification.json').exists(),'frozen evidence is immutable'
    profiles=[]
    for w,h,b,k,t in PROFILES:
        n=w*h;iw=max(1,(n-1).bit_length());cw=max(1,n.bit_length());maximum=(1<<b)-1
        rows=[];stats=Counter();input_tokens=[]
        for frame,(pixels,error) in enumerate(images(w,h,b,k)):
            result,nodes=oracle(pixels,w,h,k) if not error else ([(0,0,0,0)]*n,0)
            tag=(frame*37+5)&((1<<t)-1);rows.append(f'{error} {nodes}\n');frame_inputs=[]
            for p,value in enumerate(pixels):
                sof=int(p==0);eol=int(p%w==w-1)
                if error&1 and p==(n-1 if frame%2 and n>1 else 0):sof^=1
                if error&2 and p==n-1:eol^=1
                word=pack([(value,b),(sof,1),(eol,1),(tag if p==0 else tag^((1<<t)-1),t)])
                rows.append(f'{word:x}\n');frame_inputs.append(word)
            for p,(parent,level,canonical,area) in enumerate(result):
                word=pack([(p,iw),(parent,iw),(level,b),(canonical,1),(area,cw),(p==0,1),
                           (p%w==w-1,1),(p==n-1,1),(error,2),(tag,t)])
                rows.append(f'{word:x}\n')
            input_tokens.append(frame_inputs);stats['frames']+=1;stats['input_pixels']+=n;stats['output_records']+=n
            stats['error_'+str(error)]+=1;stats['canonical_nodes']+=nodes;stats['successful_pixels']+=n if not error else 0
        name=f'w{w}_h{h}_b{b}_k{k}_t{t}';fixture='sim/fixtures/'+name+'.txt';raw=''.join(rows).encode()
        (ROOT/fixture).write_bytes(raw);r=degree(w,h,k);g=1<<b;y=w*h*(h-1)//2
        h4=h*(w-1)+(h-1)*(w*w+w-1)
        hf=h4+((h-1)*(w-1)*(2*w+2) if k==8 else 0)
        probes=reset_ids(w,h);groups=[dict(group=g,ids=[i for i in probes if i%2==g]) for g in [0,1]] if n==256 else [dict(group=-1,ids=probes)]
        profiles.append(dict(name=name,w=w,h=h,b=b,k=k,t=t,fixture=fixture,sha256=sha(raw),statistics=dict(stats),
            stimulus_sha256=sha(json.dumps(input_tokens,separators=(',',':')).encode()),reset_ids=probes,reset_groups=groups,
            directed_degree=r,tail_bound=3*g+(20+2*k)*n+y+2*r+r*n+3,
            fresh_tail_bound=3*g+(20+2*k)*n+y+2*r+2*hf+3))
    children=['version','core_syntax','example_syntax']
    for q in profiles:children += [q['name']+'_compile',q['name']+'_main']+[q['name']+'_reset_'+str(g['group']) for g in q['reset_groups']]
    children += ['reject_'+q[0] for q in NEGATIVES]
    assert len(children)==45 and sum(q['statistics']['frames'] for q in profiles)==1680
    plan=dict(schema=1,baseline=BASELINE,frozen_before_first_hdl=True,profiles=profiles,negative_parameters=NEGATIVES,
        children=children,timeout_seconds=20,source_hashes=source_hashes(),
        oracle='independent threshold connected-component sets, canonical same-level minima, nearest strict-inclusion parent; exact complete-threshold partition certificates',
        reset_policy='37 basic states plus9 context IDs, omit only unreachable contexts; every immediate cancellation followed by full same-geometry last-bright fresh tree/area/hold/retirement',
        source_policy='actual next frozen pixel token held until real acceptance or reset cancellation',
        split_before_first_hdl='main/reset independent children; maximum profiles reset IDs partition even/odd before first HDL,23+23; each20s, no post-timeout split',
        no_synthesis=True,no_inherited_reruns=True)
    save_json(ROOT/'TEST_PLAN.json',plan);print('FROZEN',sha((ROOT/'TEST_PLAN.json').read_bytes()))
    for q in profiles:print(q['name'],q['statistics'],'resets',len(q['reset_ids']),'bounds',q['tail_bound'],q['fresh_tail_bound'])
def run(repair=False):
    raw=(ROOT/'TEST_PLAN.json').read_bytes();plan=json.loads(raw);assert source_hashes()==plan['source_hashes']
    prior_attempts=[];receipt_path=ROOT/'verification.json'
    if receipt_path.exists():
        assert repair and plan.get('repair_history'),'existing receipt blocks automatic reruns'
        for item in plan['repair_history']:
            archive_raw=(ROOT/item['archive']).read_bytes();assert sha(archive_raw)==item['archive_sha256']
            archive=json.loads(archive_raw)
            for key in ['original_plan','original_receipt']:
                value=archive[key];original=value['utf8'].encode()
                assert len(original)==value['byte_count'] and sha(original)==value['sha256']
            oldplan=json.loads(archive['original_plan']['utf8']);oldreport=json.loads(archive['original_receipt']['utf8'])
            assert oldreport['status']=='FAIL' and all(r['status'] not in ['TIMEOUT','TIMEOUT_TERMINAL'] for r in oldreport['records'])
            assert item['plan_sha256']==archive['original_plan']['sha256'] and item['receipt_sha256']==archive['original_receipt']['sha256']
            for key,value in oldplan.items():
                if key not in ['source_hashes','repair_history']:assert plan[key]==value,key
            assert oldplan['source_hashes']==archive['original_source_sha256']
            for name,value in archive['archived_sources'].items():
                original=value['utf8'].encode();assert len(original)==value['byte_count'] and sha(original)==value['sha256']==oldplan['source_hashes'][name]
            for q in oldplan['profiles']:assert sha((ROOT/q['fixture']).read_bytes())==q['sha256']
            changed=[name for name,value in oldplan['source_hashes'].items() if sha((ROOT/name).read_bytes())!=value]
            assert changed==item['allowed_source_changes']
            prior_attempts.append(dict(archive=item['archive'],archive_sha256=item['archive_sha256'],plan_sha256=item['plan_sha256'],
                receipt_sha256=item['receipt_sha256'],status=oldreport['status'],actual_records=len(oldreport['records']),
                not_run=len(oldplan['children'])-len(oldreport['records'])))
        assert sha(receipt_path.read_bytes())==plan['repair_history'][-1]['receipt_sha256'],'current receipt must exactly match archived ordinary FAIL'
    else:assert not repair,'repair requires an existing exact archived failure'
    assert len(plan['children'])==45 and plan['timeout_seconds']==20
    suite=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite';iv=str(suite/'bin/iverilog.exe');vv=str(suite/'bin/vvp.exe')
    env=dict(os.environ);env['PATH']=str(suite/'bin')+os.pathsep+str(suite/'lib')+os.pathsep+env.get('PATH','')
    report=dict(schema=1,baseline=BASELINE,status='RTL_CANDIDATE',hardware='HW_UNVERIFIED',plan_sha256=sha(raw),
        source_sha256=dict(plan['source_hashes'],**{'TEST_PLAN.json':sha(raw)}),profiles=plan['profiles'],records=[],
        planned_records=[dict(name=n,status='NOT_RUN') for n in plan['children']],prior_attempts=prior_attempts,bounded_finite_only=True)
    def save():save_json(ROOT/'verification.json',report)
    def child(name,argv,negative=False):
        assert name==plan['children'][len(report['records'])];start=time.monotonic()
        try:
            cp=subprocess.run(argv,cwd=ROOT,env=env,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=20)
            good=(cp.returncode!=0 and 'grayscale_max_tree_invalid_parameter__see_README' in cp.stderr) if negative else cp.returncode==0
            if name.endswith('_main') or '_reset_' in name:good=good and 'PASS MODE=' in cp.stdout
            rec=dict(name=name,argv=argv,timeout_seconds=20,exit_code=cp.returncode,stdout=cp.stdout,stderr=cp.stderr,
                     elapsed_seconds=round(time.monotonic()-start,6),status='PASS' if good else 'FAIL')
        except subprocess.TimeoutExpired as e:
            decode=lambda v:v.decode(errors='replace') if isinstance(v,bytes) else v or ''
            rec=dict(name=name,argv=argv,timeout_seconds=20,exit_code=None,stdout=decode(e.stdout),stderr=decode(e.stderr),
                     elapsed_seconds=round(time.monotonic()-start,6),status='TIMEOUT_TERMINAL')
        report['planned_records'][len(report['records'])]['status']=rec['status'];report['records'].append(rec);save()
        print(name,rec['status'],rec['elapsed_seconds'],flush=True)
        if rec['status']!='PASS':report['status']=rec['status'];save();raise SystemExit('stopped; preserve exact evidence; timeout terminal')
    child('version',[iv,'-V'])
    child('core_syntax',[iv,'-g2012','-Wall','-tnull','-s','grayscale_max_tree','-f','files.f'])
    child('example_syntax',[iv,'-g2012','-Wall','-tnull','-s','region_tree8','-f','example/files.f'])
    with tempfile.TemporaryDirectory(prefix='anscore_c21_max_tree_') as temporary:
        for q in plan['profiles']:
            assert sha((ROOT/q['fixture']).read_bytes())==q['sha256'];binary=str(Path(temporary)/(q['name']+'.vvp'))
            argv=[iv,'-g2012','-Wall','-s','tb_grayscale_max_tree','-o',binary]
            for key,value in dict(WIDTH=q['w'],HEIGHT=q['h'],PIXEL_W=q['b'],CONNECTIVITY=q['k'],TAG_W=q['t'],FRAMES=q['statistics']['frames'],RESETS=len(q['reset_ids'])).items():argv+=['-P',f'tb_grayscale_max_tree.{key}={value}']
            child(q['name']+'_compile',argv+['rtl/grayscale_max_tree.sv','sim/tb_grayscale_max_tree.sv'])
            child(q['name']+'_main',[vv,binary,'+MODE=0','+GROUP=-1','+COUNT=0','+FIXTURE='+q['fixture']])
            for group in q['reset_groups']:
                child(q['name']+'_reset_'+str(group['group']),[vv,binary,'+MODE=1','+GROUP='+str(group['group']),'+COUNT='+str(len(group['ids'])),'+FIXTURE='+q['fixture']])
        for name,w,h,b,k,t in NEGATIVES:
            argv=[iv,'-g2012','-tnull','-s','grayscale_max_tree']
            for key,value in dict(WIDTH=w,HEIGHT=h,PIXEL_W=b,CONNECTIVITY=k,TAG_W=t).items():argv+=['-P',f'grayscale_max_tree.{key}={value}']
            child('reject_'+name,argv+['rtl/grayscale_max_tree.sv'],True)
    assert len(report['records'])==45 and source_hashes()==plan['source_hashes']
    report['status']='UNIT_SIM_PASS';save();print('REPORT',sha((ROOT/'verification.json').read_bytes()))
if __name__=='__main__':
    parser=argparse.ArgumentParser();group=parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--freeze',action='store_true');group.add_argument('--run',action='store_true');parser.add_argument('--repair',action='store_true');args=parser.parse_args()
    if args.repair and not args.run:parser.error('--repair requires --run')
    freeze() if args.freeze else run(args.repair)
