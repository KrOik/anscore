"""Authorized one-shot numerical preparation payload; not an authoring entry point."""
from pathlib import Path
import argparse
import json
from reference import expected

ROOT=Path(__file__).resolve().parent

def write_vectors(path: Path,cases: list[dict]) -> None:
    lines=[str(len(cases))]
    for case in cases:
        snapshots=[v for snapshot in case['snapshots'] for v in snapshot]
        lines.append(' '.join(map(str,[case['ordinal'],case['k'],case['iterations'],case['tag'],
                                      len(case['records']),case['errors'],len(snapshots),len(case['coefficients']),case['tail_periods']])))
        lines.extend(' '.join(map(str,[pixel]+marker)) for pixel,marker in zip(case['pixels'],case['markers']))
        lines.extend(map(str,case['coefficients']))
        lines.extend(map(str,snapshots))
        lines.extend(' '.join(map(str,record)) for record in case['records'])
    path.write_text('\n'.join(lines)+'\n',encoding='ascii',newline='\n')

def main() -> None:
    parser=argparse.ArgumentParser();parser.add_argument('--authorized-payload',action='store_true',required=True)
    parser.parse_args()
    table=json.loads((ROOT/'CASE_TABLE.json').read_text())
    if not (ROOT/'preparation/LOCK.json').is_file(): raise SystemExit('gate lock required')
    directory=ROOT/'fixtures';directory.mkdir(exist_ok=False)
    for profile in table['profiles']:
        dest=directory/profile['name'];dest.mkdir()
        cases=[expected(profile,c,i,table) for i,c in enumerate(profile['cases'])]
        (dest/'expected.json').write_text(json.dumps(cases,indent=2)+'\n',encoding='utf-8',newline='\n')
        write_vectors(dest/'vectors.txt',cases)
        if profile['reset_probes']:
            for name in ['reset_old','reset_fresh']:
                case=expected(profile,table[name],0,table)
                (dest/(name+'.json')).write_text(json.dumps([case],indent=2)+'\n',encoding='utf-8',newline='\n')
                write_vectors(dest/(name+'.txt'),[case])
        if profile['name']=='p3':
            signed=next(c for c in cases if c['id']=='signed_half')
            if [signed['snapshots'][0][i] for i in [5,6]]!=[128,128]: raise AssertionError('signed half certificate')
    print('PREPARED profiles=5 cases=16 reset_cases=2')

if __name__=='__main__': main()
