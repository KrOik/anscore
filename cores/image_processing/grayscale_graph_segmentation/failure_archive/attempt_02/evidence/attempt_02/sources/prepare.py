"""Approved one-shot numerical preparation; never launches HDL or upstream code."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import sys
from oracle import certificates, records, ordered_edges

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path,value: object) -> None:
    path.write_text(json.dumps(value,indent=2)+'\n',encoding='utf-8',newline='\n')


def pattern(case: dict,width: int,height: int) -> list[int]:
    name = case['pattern']
    if name == 'explicit':
        out = case['pixels'][:]
    else:
        out = []
        for y in range(height):
            for x in range(width):
                if name == 'flat': p = case['value']
                elif name == 'ramp': p = (3*x+5*y)%256
                elif name == 'checker': p = 255*((x+y)%2)
                elif name == 'formula': p = (37*x+53*y+11*x*y+19)%256
                elif name == 'halves': p = 0 if x < width//2 else 255
                elif name == 'islands': p = 200 if x%4 < 2 and y%4 < 2 else 20
                elif name == 'bands': p = [0,0,5,10,10,10][min(x,5)]
                else: raise ValueError(f'unknown frozen pattern: {name}')
                out.append(p)
    assert len(out) == width*height and all(0 <= p <= 255 for p in out)
    return out


def make_case(case: dict,profile: dict,ordinal: int,tag: int | None=None) -> dict:
    width,height = profile['width'],profile['height']
    n = width*height
    pixels = pattern(case,width,height)
    markers = [[int(i==0),int(i%width==width-1),int(i==n-1)] for i in range(n)]
    for field,column in (('flip_sof',0),('flip_eol',1),('flip_last',2)):
        if field in case:
            index = case[field]
            assert 0 <= index < n
            markers[index][column] ^= 1
    minimum = n if case['min'] == 'N' else case['min']
    count_w = max(1,n.bit_length())
    assert 0 <= minimum < 1 << count_w
    tag = ((3*ordinal+1)&((1<<profile['tag_w'])-1)) if tag is None else tag
    output,errors = records(pixels,markers,width,height,case['k'],minimum,tag)
    edges = ordered_edges(pixels,width,height)
    scans = [] if errors or not edges else [dict(phase=phase,edges=len(edges),
             first_weight=edges[0][0],last_weight=edges[-1][0]) for phase in range(2 if minimum>1 else 1)]
    return dict(id=case['id'],ordinal=ordinal,k=case['k'],minimum=minimum,tag=tag,
                pixels=pixels,markers=markers,records=output,errors=errors,sort=scans)


def write_vectors(path: Path,cases: list[dict]) -> None:
    lines = [str(len(cases))]
    for case in cases:
        lines.append(' '.join(map(str,[case['ordinal'],case['k'],case['minimum'],case['tag'],
                                      len(case['records']),case['errors']])))
        lines.extend(' '.join(map(str,[pixel]+marker)) for pixel,marker in zip(case['pixels'],case['markers']))
        lines.extend(' '.join(map(str,row)) for row in case['records'])
    path.write_text('\n'.join(lines)+'\n',encoding='ascii',newline='\n')


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--approved-author-seal',required=True)
    args = parser.parse_args()
    assert args.approved_author_seal == sha(ROOT/'AUTHOR_INPUTS.json'),'author approval mismatch'
    author = json.loads((ROOT/'AUTHOR_INPUTS.json').read_text(encoding='utf-8-sig'))
    for rel,digest in author['sources'].items():
        assert sha(ROOT/rel) == digest,f'author input changed: {rel}'
    for rel,digest in author['external_sources'].items():
        assert sha(REPO/rel) == digest,f'backend changed: {rel}'
    lock = json.loads((ROOT/'preparation/LOCK.json').read_text())
    assert lock['author_sha256'] == args.approved_author_seal and lock['status'] == 'STARTED_ONCE'
    assert not (ROOT/'SOURCE_SEAL.json').exists()
    assert not (ROOT/'fixtures').exists()
    table = json.loads((ROOT/'CASE_TABLE.json').read_text())
    certs = certificates()
    assert len(certs) == 8
    total_cases,total_outputs,reset_jobs = 0,0,0
    fixture_paths = []
    for profile in table['profiles']:
        folder = ROOT/'fixtures'/profile['name']
        folder.mkdir(parents=True,exist_ok=False)
        cases = [make_case(case,profile,i) for i,case in enumerate(profile['cases'])]
        assert len({case['id'] for case in cases}) == len(cases)
        n = profile['width']*profile['height']
        old = make_case(dict(id='reset_old',pattern='flat',value=7,k=0,min='N'),profile,0,0)
        fresh = make_case(dict(id='reset_fresh',pattern='flat',value=7,k=64,min=1),profile,0,
                          (1<<profile['tag_w'])-1)
        for name,items in (('vectors',cases),('reset_old',[old]),('reset_fresh',[fresh])):
            text_path = folder/(name+'.txt')
            json_path = folder/('expected.json' if name=='vectors' else name+'.json')
            write_vectors(text_path,items)
            write_json(json_path,items)
            fixture_paths += [text_path.relative_to(ROOT).as_posix(),json_path.relative_to(ROOT).as_posix()]
        total_cases += len(cases)
        total_outputs += sum(len(c['records']) for c in cases)
        reset_jobs += len(profile['reset_probes'])
        if profile['name']=='p5':
            assert cases[0]['records'][0][2:4] == [4096,1]
            assert cases[1]['records'][0][2:4] == [2048,2]
            assert {r[1] for r in cases[1]['records']} == {0,32}
    assert total_cases == table['normal_cases'] == 44
    assert total_outputs == 10197 and reset_jobs == table['reset_jobs'] == 43
    write_json(ROOT/'BOUNDARY_CERTIFICATES.json',certs)
    fixture_paths.append('BOUNDARY_CERTIFICATES.json')
    # Tool paths/hashes and exact expanded child descriptions are metadata only.
    import run_tests
    tools = run_tests.tool_inventory()
    for rel,digest in author['sources'].items():
        assert sha(ROOT/rel) == digest,f'author changed during preparation: {rel}'
    for rel,digest in author['external_sources'].items():
        assert sha(REPO/rel) == digest,f'backend changed during preparation: {rel}'
    seal = dict(schema=1,status='PREPARED_NOT_HDL_RUN',author_sha256=args.approved_author_seal,
                sources=author['sources'],external_sources=author['external_sources'],
                fixtures={rel:sha(ROOT/rel) for rel in sorted(fixture_paths)},
                tools=tools,children=run_tests.child_plan(),
                normal_cases=44,normal_replays=88,normal_output_records=20394,
                reset_jobs=43,reset_fresh_output_records=2843,reset_aborted_output_records=4,
                certificates=8,hardware='HW_UNVERIFIED')
    write_json(ROOT/'SOURCE_SEAL.json',seal)
    write_json(ROOT/'preparation/BUILT.json',dict(status='PREPARED_ORACLE_ASSERTIONS_PASS_HW_NOT_RUN',
               source_seal_sha256=sha(ROOT/'SOURCE_SEAL.json'),author_sha256=args.approved_author_seal,
               files=seal['fixtures'],normal_cases=44,reset_jobs=43,compiler_launched=False))
    print('PASS PREPARE profiles=6 cases=44 reset_jobs=43 certificates=8 HDL_NOT_RUN')
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f'PREPARATION_FAILED {type(exc).__name__}: {exc}',file=sys.stderr)
        raise
