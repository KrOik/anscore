"""Fixed23 models once, reachable only through separately approved preparation."""
# SPDX-License-Identifier: Apache-2.0
import argparse,hashlib,json,sys
from pathlib import Path
if sys.flags.optimize:raise RuntimeError('optimized Python forbidden')
sys.dont_write_bytecode=True
P=Path(__file__).resolve().parent

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def write(path,value):path.write_text(json.dumps(value,indent=2)+'\n',encoding='utf-8',newline='\n')

def prepare(destination,author_digest,approval_path,approval_digest):
    seal=json.loads((P/'AUTHOR_SEAL.json').read_bytes())
    assert sha(P/'AUTHOR_SEAL.json')==author_digest
    actual={p.relative_to(P).as_posix():sha(p) for p in P.rglob('*') if p.is_file() and p.name!='AUTHOR_SEAL.json'}
    assert actual==seal['sources']
    approval_path=approval_path.resolve()
    assert approval_path.is_relative_to((Path(seal['repository_root'])/'.git').resolve())
    assert sha(approval_path)==approval_digest
    approval=json.loads(approval_path.read_bytes())
    assert approval['stage']=='prepare' and approval['approved_by']=='root'
    assert approval['approved_author_sha256']==author_digest
    assert approval['max_invocations']==1 and approval['hard_seconds_per_tree']==20 and approval['automatic_retry'] is False
    assert len(approval['independent_reviews'])>=2
    for name,digest in approval['independent_reviews'].items():
        path=(Path(seal['repository_root'])/name).resolve()
        assert path.is_relative_to(Path(seal['repository_root']).resolve()) and sha(path)==digest
    assert destination.resolve()==(Path(seal['repository_root'])/seal['package']/'preparation/generated').resolve()
    # Import ONLY inside the once-only numerical preparation process.
    from reference import materialize,optimum,validate_witness
    assert not destination.exists(),'preparation is exclusive; no retry'
    destination.mkdir(parents=True)
    table=json.loads((P/'CASE_TABLE.json').read_bytes())
    plan=json.loads((P/'PREPARATION_PLAN.json').read_bytes())
    assert plan['model_calls']==23 and len(table['cases'])==23
    profiles={p['id']:p for p in table['profiles']}
    cases=[];byname={};witness_checks=0
    for ordinal,case in enumerate(table['cases']):
        p=profiles[case['profile']]
        graph=materialize(p,case);target=optimum(graph)
        assert target['error']==case.get('error',0)
        assert target['feasible']==(not case.get('error') and not case.get('infeasible'))
        assert target['cost']==case.get('cost',0),(case['name'],target['cost'])
        vertices=0
        if target['feasible']:
            vertices=validate_witness(graph,target,target['edges']);witness_checks+=1
        item=dict(id=ordinal,name=case['name'],profile=case['profile'],n=graph['n'],
                  terminals=list(graph['terminals']),terminal_mask=graph['terminal_mask'],
                  edges=[[u,v,w] for (u,v),w in sorted(graph['edges'].items())],
                  inputs=graph['inputs'],target=target,reference_witness_vertices=vertices)
        cases.append(item);byname[case['name']]=item
    assert witness_checks==14
    jobs=[]
    for j in table['normal_jobs']:
        profile=profiles[j['profile']];mask=(1<<profile['T'])-1
        frames=[dict(case=byname[name]['id'],tag=(i+1)&mask) for i,name in enumerate(j['cases'])]
        jobs.append(dict(name=j['name'],profile=j['profile'],reset=-1,
                         future=int('future_offer' in j),frames=frames))
    for reset,j in enumerate(table['reset_jobs']):
        jobs.append(dict(name=j['name'],profile=j['profile'],reset=reset,future=0,
                         frames=[dict(case=byname[j['owner']]['id'],tag=85),
                                 dict(case=byname[j['fresh']]['id'],tag=170)]))
    assert len(jobs)==12 and sum(len(j['frames']) for j in jobs)==35
    data=dict(schema='steiner-fixed23-v1',case_table_sha256=sha(P/'CASE_TABLE.json'),
              preparation_plan_sha256=sha(P/'PREPARATION_PLAN.json'),
              model_calls=23,materialize_calls=23,witness_checks=14,
              profiles=table['profiles'],cases=cases,jobs=jobs)
    write(destination/'DATA.json',data)
    for j in jobs:
        lines=[str(len(j['frames']))]
        for f in j['frames']:
            c=cases[f['case']]
            lines.append(f"{c['id']} {f['tag']} {c['terminal_mask']}")
            lines.extend(' '.join(map(str,beat)) for beat in c['inputs'])
        lines.append('-99')
        (destination/(j['name']+'.txt')).write_text('\n'.join(lines)+'\n',encoding='ascii',newline='\n')
    files={p.name:sha(p) for p in destination.iterdir() if p.is_file()}
    assert len(files)==13
    write(destination/'MANIFEST.json',dict(schema=1,status='FIXED23_PREPARED_ONCE',
          files_sha256=files,models_during_hdl=False,model_calls=23))
    print(json.dumps(dict(status='FIXED23_PREPARED_ONCE',cases=23,jobs=12,files=14,
                          model_calls=23,materialize_calls=23,witness_checks=14)))

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--once',type=Path,required=True)
    parser.add_argument('--approved-author',required=True);parser.add_argument('--approval',type=Path,required=True)
    parser.add_argument('--approved-approval',required=True)
    args=parser.parse_args();prepare(args.once.resolve(),args.approved_author,args.approval,args.approved_approval)
