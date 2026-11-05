"""Separate approval gates for one preparation and one fixed 33-child HDL attempt."""
from __future__ import annotations
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import sys
from process_tree import execute

ROOT=Path(__file__).resolve().parent
REPO=ROOT.parents[2]
PYTHON=Path(r'C:\Program Files\Python312\python.exe')
TOOL_HOME=REPO/'tools/oss-cad-suite/oss-cad-suite'
IVERILOG=TOOL_HOME/'bin/iverilog.exe'
VVP=TOOL_HOME/'bin/vvp.exe'
DSU=REPO/'cores/acceleration/disjoint_set_union/rtl/disjoint_set_union.sv'
HARD_SECONDS=20


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding='utf-8-sig'))


def write_json(path: Path,value: object) -> None:
    path.write_text(json.dumps(value,indent=2)+'\n',encoding='utf-8',newline='\n')


def tool_inventory() -> dict:
    return {name:dict(path=str(path.resolve()),sha256=sha(path)) for name,path in
            (('PYTHON',PYTHON),('IVERILOG',IVERILOG),('VVP',VVP))}


def dependency_guard() -> dict:
    dep=read_json(ROOT/'DEPENDENCIES.json')
    for rel,digest in dep['external_sources'].items():
        assert sha(REPO/rel)==digest,f'changed inherited dependency: {rel}'
    baseline=REPO/dep['baseline_manifest']
    assert sha(baseline)==dep['baseline_manifest_sha256']
    old=read_json(baseline)
    package=next(p for p in old['packages'] if p['path']=='cores/acceleration/disjoint_set_union')
    assert package['sha256']['rtl/disjoint_set_union.sv']==dep['external_sources'][DSU.relative_to(REPO).as_posix()]
    return dep


def author_guard(digest: str) -> dict:
    assert sha(ROOT/'AUTHOR_INPUTS.json')==digest,'exact author approval required'
    author=read_json(ROOT/'AUTHOR_INPUTS.json')
    for rel,expected in author['sources'].items():
        assert sha(ROOT/rel)==expected,f'author input changed: {rel}'
    assert author['external_sources']==dependency_guard()['external_sources']
    return author


def child_plan() -> list[dict]:
    plan=read_json(ROOT/'TEST_PLAN.json')
    profiles={p['name']:p for p in plan['profiles']}
    tokens={'{PYTHON}':str(PYTHON.resolve()),'{IVERILOG}':str(IVERILOG.resolve()),
            '{VVP}':str(VVP.resolve()),'{DSU}':str(DSU.resolve())}
    common=['-g2012','-Wall','-Wno-timescale']
    rtl=[str(DSU.resolve()),'rtl/grayscale_graph_segmentation.sv']
    result=[]
    for item in plan['slots']:
        slot=copy.deepcopy(item)
        kind=slot['kind']
        if kind=='compile':
            p=profiles[slot['profile']]
            slot['argv']=[str(IVERILOG.resolve())]+common+['-s','tb_grayscale_graph_segmentation',
                '-P',f'tb_grayscale_graph_segmentation.WIDTH={p["width"]}',
                '-P',f'tb_grayscale_graph_segmentation.HEIGHT={p["height"]}',
                '-P',f'tb_grayscale_graph_segmentation.TAG_W={p["tag_w"]}',
                '-o',f'{{ARTIFACT}}/{p["name"]}.vvp']+rtl+['sim/tb_grayscale_graph_segmentation.sv']
        elif kind=='simulation':
            slot['argv']=[str(VVP.resolve()),f'{{ARTIFACT}}/{slot["profile"]}.vvp',
                          f'+PROFILE={slot["profile"]}',f'+MODE={slot["mode"]}',f'+STALL={slot["stall"]}']
        elif kind=='reject':
            slot['argv']=[str(IVERILOG.resolve())]+common+['-tnull','-s','grayscale_graph_segmentation',
                '-P',f'grayscale_graph_segmentation.{slot["parameter"]}={slot["value"]}']+rtl
        else:
            slot['argv']=[tokens.get(arg,arg) for arg in slot['argv']]
        slot['hard_seconds']=HARD_SECONDS
        result.append(slot)
    assert len(result)==33 and sum(s['kind']=='simulation' for s in result)==17
    assert sum(s['kind']=='reject' for s in result)==6
    return result


def sort_lines(prefix: str,profile: str,ordinal: int,case: dict) -> list[str]:
    return [f'{prefix} {profile} {ordinal} {s["phase"]} {s["edges"]} {s["first_weight"]} {s["last_weight"]}'
            for s in case['sort']]


def record_lines(prefix: str,profile: str,ordinal: int,case: dict) -> list[str]:
    return [f'{prefix} {profile} {ordinal} '+' '.join(map(str,row)) for row in case['records']]


def frame_line(profile: str,ordinal: int,case: dict) -> str:
    return f'FRAME {profile} {ordinal} {len(case["records"])} {case["errors"]} {case["tag"]}'


def validate_simulation(slot: dict,lines: list[str]) -> None:
    profile=slot['profile']
    folder=ROOT/'fixtures'/profile
    table=read_json(ROOT/'CASE_TABLE.json')
    p=next(p for p in table['profiles'] if p['name']==profile)
    finishes=[line for line in lines if re.fullmatch(r'sim[/\\]tb_grayscale_graph_segmentation\.sv:\d+: \$finish called at \d+ \(1ps\)',line)]
    assert len(finishes)==1,'one exact Icarus finish diagnostic required'
    lines=[line for line in lines if line not in finishes]
    if slot['mode']=='main':
        cases=read_json(folder/'expected.json')
        expected=[]
        for i,case in enumerate(cases):
            expected+=sort_lines('SORT',profile,i,case)+record_lines('REC',profile,i,case)
            expected.append(frame_line(profile,i,case))
        count=sum(len(case['records']) for case in cases)
        expected.append(f'PASS MAIN profile={profile} stall={slot["stall"]} frames={len(cases)} records={count}')
        assert lines==expected,'main raw tuple/sort/frame/summary stream differs'
        return
    old=read_json(folder/'reset_old.json')[0]
    fresh=read_json(folder/'reset_fresh.json')[0]
    probes=p['reset_probes']
    n=p['width']*p['height']
    cursor=0
    states={'capture_prefix':0,'clear_wait':2,'prefix_sum':14,'scatter_write':11,
            'fh_meta_a':22,'fh_test_b':26,'union_pending':29,'minimum_pass':15,
            'output_held':36,'output_prefix':36,'next_offer':36}
    for i,name in enumerate(probes):
        before=[]
        if name=='minimum_pass':
            before=sort_lines('ABORTSORT',profile,i,old)[:1]
        elif name in ('output_held','output_prefix','next_offer'):
            before=sort_lines('ABORTSORT',profile,i,old)
        if name=='output_prefix':
            before+=record_lines('ABORTREC',profile,i,old)[:1]
        assert lines[cursor:cursor+len(before)]==before,'aborted raw sort/prefix mismatch'
        cursor+=len(before)
        row=lines[cursor].split();cursor+=1
        assert len(row)==19 and row[:4]==['PROBE',profile,str(i),name],'probe identity'
        sent,retired,state,post,dsu_valid,out_valid,out_ready,captured,scatter,edge,ra,rb,product,op,backend=map(int,row[4:])
        assert sent==(1 if name=='capture_prefix' else n) and retired==int(name=='output_prefix')
        assert state==states[name] and out_ready==0
        assert out_valid==int(name in ('output_held','output_prefix','next_offer'))
        if name=='capture_prefix': assert captured==1 and post==0
        if name=='scatter_write': assert scatter==1
        if name in ('fh_meta_a','fh_test_b','union_pending'): assert ra!=rb and post==0
        if name=='union_pending': assert dsu_valid==0 and op==1 and 2<=backend<=6
        if name=='minimum_pass': assert post==1 and edge==0
        if name=='next_offer':
            assert lines[cursor]==f'OFFER {profile} {i} {fresh["tag"]}';cursor+=1
        assert lines[cursor]==f'RESETAT {profile} {i} {states[name]}';cursor+=1
        for reset_edge in range(3):
            assert lines[cursor]==f'RESETEDGE {profile} {i} {reset_edge}';cursor+=1
        if name=='next_offer':
            assert lines[cursor]==f'NEXTHANDSHAKE {profile} {i} {fresh["tag"]}';cursor+=1
        after=sort_lines('SORT',profile,i,fresh)+record_lines('REC',profile,i,fresh)+[frame_line(profile,i,fresh)]
        assert lines[cursor:cursor+len(after)]==after,'fresh complete frame mismatch'
        cursor+=len(after)
    summary=f'PASS RESET profile={profile} probes={len(probes)} fresh_records={n*len(probes)} aborted_records={int(n>1)} reset_edges={3*len(probes)} next_offer=1'
    assert lines[cursor:]==[summary],'reset terminal stream mismatch'


def invoke(slot: dict,out: Path,env: dict,cwd: Path=ROOT) -> None:
    actual=[arg.replace('{ARTIFACT}',str((out/'artifacts').resolve())) for arg in slot['plan_argv']]
    slot['working_directory']=str(cwd.resolve())
    result=execute(actual,cwd,env,HARD_SECONDS)
    raw_out=result.pop('stdout');raw_err=result.pop('stderr')
    stdout_path=out/(slot['name']+'.stdout.raw')
    stderr_path=out/(slot['name']+'.stderr.raw')
    stdout_path.write_bytes(raw_out);stderr_path.write_bytes(raw_err)
    slot.update(result,stdout_file=stdout_path.relative_to(ROOT).as_posix(),
                stderr_file=stderr_path.relative_to(ROOT).as_posix(),
                stdout_sha256=sha(stdout_path),stderr_sha256=sha(stderr_path))
    if slot['failure']:
        raise RuntimeError(slot['failure'])
    if slot['kind']=='reject':
        lines=(raw_out+raw_err).decode('utf-8',errors='strict').splitlines()
        assert slot['returncode']!=0 and any('grayscale_graph_segmentation_invalid_parameters__see_README' in line for line in lines),'missing named reject'
        slot['status']='EXPECTED_REJECT'
        return
    assert slot['returncode']==0,f'child returncode {slot["returncode"]}'
    if slot['kind'] in ('silent','compile'):
        assert raw_out==raw_err==b'','unexpected compiler diagnostics'
    elif slot['kind']=='exact':
        assert raw_err==b'','unexpected exact-child stderr'
        lines=raw_out.decode('utf-8',errors='strict').splitlines()
        assert lines==[slot['expected']],'exact child diagnostic mismatch'
    elif slot['kind']=='version':
        lines=(raw_out+raw_err).decode('utf-8',errors='strict').splitlines()
        assert any(re.fullmatch(r'Icarus Verilog version .+',line) for line in lines),'missing tool version'
    elif slot['kind']=='simulation':
        assert raw_err==b'','unexpected simulator stderr'
        lines=raw_out.decode('utf-8',errors='strict').splitlines()
        validate_simulation(slot,lines)
    else:
        raise RuntimeError('unknown sealed child kind')
    slot['status']='PASS'


def environment() -> dict:
    env=os.environ.copy()
    env['PYTHONDONTWRITEBYTECODE']='1'
    env['PYTHONIOENCODING']='utf-8'
    env['PATH']=str(TOOL_HOME/'bin')+os.pathsep+env.get('PATH','')
    return env


def prepare_once(approved: str) -> int:
    author_guard(approved)
    tools=tool_inventory()
    out=ROOT/'preparation'
    out.mkdir(exist_ok=False)
    write_json(out/'LOCK.json',dict(status='STARTED_ONCE',author_sha256=approved))
    slot=dict(name='prepare',kind='exact',plan_argv=[str(PYTHON.resolve()),'-B','prepare.py',
              '--approved-author-seal',approved],expected='PASS PREPARE profiles=6 cases=44 reset_jobs=43 certificates=8 HDL_NOT_RUN',
              status='NOT_RUN',hard_seconds=20)
    receipt=dict(schema=1,status='STARTED',author_sha256=approved,tools=tools,
                 hard_seconds=20,automatic_retry=False,children=[slot],compiler_launched=False)
    write_json(out/'receipt.json',receipt)
    try:
        invoke(slot,out,environment())
        built=read_json(out/'BUILT.json')
        assert built['status']=='PREPARED_ORACLE_ASSERTIONS_PASS_HW_NOT_RUN'
        assert built['source_seal_sha256']==sha(ROOT/'SOURCE_SEAL.json')
        assert read_json(ROOT/'SOURCE_SEAL.json')['tools']==tools
        author_guard(approved)
        receipt.update(status='PREPARED_ORACLE_ASSERTIONS_PASS_HW_NOT_RUN',source_seal_sha256=sha(ROOT/'SOURCE_SEAL.json'))
    except Exception as exc:
        slot['status']='TIMEOUT' if slot.get('timed_out') else 'FAIL'
        receipt.update(status='FAILED_STOPPED',failure=f'{type(exc).__name__}: {exc}')
    write_json(out/'receipt.json',receipt)
    print(receipt['status'])
    return 0 if receipt['status']=='PREPARED_ORACLE_ASSERTIONS_PASS_HW_NOT_RUN' else 1


def run_once(approved: str,approved_prep: str) -> int:
    assert sha(ROOT/'SOURCE_SEAL.json')==approved,'separate exact source-seal approval required'
    assert sha(ROOT/'preparation/receipt.json')==approved_prep,'exact preparation-receipt approval required'
    seal=read_json(ROOT/'SOURCE_SEAL.json')
    author_guard(seal['author_sha256'])
    for group in ('sources','fixtures'):
        for rel,digest in seal[group].items():
            assert sha(ROOT/rel)==digest,f'sealed {group} changed: {rel}'
    assert seal['external_sources']==dependency_guard()['external_sources']
    assert seal['tools']==tool_inventory() and seal['children']==child_plan()
    prep=read_json(ROOT/'preparation/receipt.json')
    assert prep['status']=='PREPARED_ORACLE_ASSERTIONS_PASS_HW_NOT_RUN' and prep['source_seal_sha256']==approved
    out=ROOT/'evidence/attempt_01'
    out.mkdir(parents=True,exist_ok=False)
    write_json(out/'LOCK.json',dict(status='STARTED_ONCE',source_seal_sha256=approved,preparation_receipt_sha256=approved_prep))
    copies=out/'sources'
    for rel in list(seal['sources'])+list(seal['fixtures'])+['AUTHOR_INPUTS.json','SOURCE_SEAL.json','preparation/receipt.json']:
        target=copies/rel
        target.parent.mkdir(parents=True,exist_ok=True)
        target.write_bytes((ROOT/rel).read_bytes())
        assert sha(target)==sha(ROOT/rel),'tested input copy mismatch'
    (out/'artifacts').mkdir()
    slots=[]
    for description in seal['children']:
        slot=copy.deepcopy(description)
        slot['plan_argv']=slot.pop('argv');slot['status']='NOT_RUN'
        slots.append(slot)
    receipt=dict(schema=1,status='STARTED',source_seal_sha256=approved,
        preparation_receipt_sha256=approved_prep,external_sha256=seal['external_sources'],
        tested_copies_sha256={p.relative_to(copies).as_posix():sha(p) for p in sorted(copies.rglob('*')) if p.is_file()},
        tools=seal['tools'],children=slots,hard_seconds=20,automatic_retry=False,
        numerical_scope='Only fixed B28-C qualification matrix; inherited matrices/checker NOT_RUN',hardware='HW_UNVERIFIED')
    write_json(out/'receipt.json',receipt)
    for slot in slots:
        try:
            for rel,digest in receipt['tested_copies_sha256'].items():
                assert sha(copies/rel)==digest,f'tested copy changed: {rel}'
            dependency_guard()
            invoke(slot,out,environment(),copies)
            for rel,digest in receipt['tested_copies_sha256'].items():
                assert sha(copies/rel)==digest,f'tested copy changed during child: {rel}'
            for group in ('sources','fixtures'):
                for rel,digest in seal[group].items():
                    assert sha(ROOT/rel)==digest,f'original sealed input changed: {rel}'
            dependency_guard()
        except Exception as exc:
            slot['status']='TIMEOUT' if slot.get('timed_out') else 'FAIL'
            receipt.update(status='FAILED_STOPPED',first_failure=slot['name'],failure=f'{type(exc).__name__}: {exc}')
            write_json(out/'receipt.json',receipt)
            print('FAILED_STOPPED '+slot['name'])
            return 1
        write_json(out/'receipt.json',receipt)
    receipt.update(status='PASS',children_count=33,simulations=17,named_parameter_rejects=6,
                   normal_replays=88,normal_output_records=20394,reset_jobs=43,
                   reset_fresh_output_records=2843,reset_aborted_output_records=4)
    receipt['artifacts_sha256']={p.relative_to(out).as_posix():sha(p) for p in sorted((out/'artifacts').glob('*.vvp'))}
    write_json(out/'receipt.json',receipt)
    print('PASS B28_C children=33 simulations=17 rejects=6')
    return 0


def main() -> int:
    parser=argparse.ArgumentParser()
    sub=parser.add_subparsers(dest='action',required=True)
    prep=sub.add_parser('prepare');prep.add_argument('--approved-author-seal',required=True)
    run=sub.add_parser('run');run.add_argument('--approved-source-seal',required=True)
    run.add_argument('--approved-preparation-receipt',required=True)
    args=parser.parse_args()
    if args.action=='prepare': return prepare_once(args.approved_author_seal)
    return run_once(args.approved_source_seal,args.approved_preparation_receipt)


if __name__=='__main__':
    raise SystemExit(main())
