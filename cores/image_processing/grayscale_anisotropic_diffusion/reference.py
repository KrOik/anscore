"""Independent snapshot/Fraction definition; never run implicitly by authoring tools."""
from __future__ import annotations
from fractions import Fraction
from pathlib import Path
import argparse
import hashlib
import json

ROOT=Path(__file__).resolve().parent

def round_away(value: Fraction) -> int:
    if value<0:
        return -round_away(-value)
    return (2*value.numerator+value.denominator)//(2*value.denominator)

def pixels_for(profile: dict,case: dict,table: dict) -> list[int]:
    width,height=profile['width'],profile['height']
    pattern=case['pattern']
    if pattern=='flat': return [case['value']]*(width*height)
    if pattern=='explicit': return list(case['pixels'])
    if pattern=='asym12':
        if (width,height)!=(4,3): raise ValueError('asym12 geometry')
        return list(table['asym12'])
    if pattern=='ramp': return [(i*37+11)%256 for i in range(width*height)]
    if pattern=='checker01': return [(x+y)%2 for y in range(height) for x in range(width)]
    if pattern=='step_x': return [0 if x<width//2 else 255 for y in range(height) for x in range(width)]
    if pattern=='gradient2d': return [(x*7+y*11+(x*y)%17)%256 for y in range(height) for x in range(width)]
    raise ValueError(pattern)

def expected(profile: dict,case: dict,ordinal: int,table: dict) -> dict:
    width,height=profile['width'],profile['height']
    pixels=pixels_for(profile,case,table)
    if len(pixels)!=width*height or any(not 0<=p<=255 for p in pixels): raise ValueError('pixels')
    tag=((ordinal*7)+1)&((1<<profile['tag_w'])-1)
    markers=[[int(i==0),int(i%width==width-1),int(i==len(pixels)-1)] for i in range(len(pixels))]
    errors=(8 if case['k']==0 else 0)|(16 if case['iterations']>16 else 0)
    for column,name in enumerate(['sof','eol','last']):
        if 'flip_'+name in case:
            markers[case['flip_'+name]][column]^=1
            errors|=1<<column
    coefficients=[];snapshots=[];summaries=[]
    state=[sample*256 for sample in pixels]
    if not errors and case['iterations']:
        k2=case['k']**2
        for difference in range(256):
            ratio=Fraction(256*k2,k2+difference*difference)
            coefficients.append(ratio.numerator//ratio.denominator)
        for iteration in range(case['iterations']):
            old=[state[row*width:(row+1)*width] for row in range(height)]
            fresh=[]
            for y in range(height):
                for x in range(width):
                    center=old[y][x]
                    neighbors=[old[max(0,y-1)][x],old[min(height-1,y+1)][x],
                               old[y][max(0,x-1)],old[y][min(width-1,x+1)]]
                    change=Fraction(0)
                    for neighbor in neighbors:
                        delta=neighbor-center
                        index=(abs(delta)+128)//256
                        change+=Fraction(delta*coefficients[index],256*8)
                    value=center+round_away(change)
                    if not min([center]+neighbors)<=value<=max([center]+neighbors):
                        raise AssertionError('local maximum principle')
                    fresh.append(value)
            state=fresh
            snapshots.append(list(state))
            summaries.append([iteration,len(state),min(state),max(state),sum(state)])
    if errors:
        records=[[0,0,0,0,0,0,1,0,errors,tag]]
        tail=1
    else:
        records=[[i%width,i//width,(value+128)//256,value,int(i==0),
                  int(i%width==width-1),int(i==len(state)-1),1,0,tag] for i,value in enumerate(state)]
        tail=3 if case['iterations']==0 else 7429+case['iterations']*(37*len(pixels)+1)
    return dict(id=case['id'],ordinal=ordinal,k=case['k'],iterations=case['iterations'],tag=tag,
                pixels=pixels,markers=markers,errors=errors,coefficients=coefficients,
                snapshots=snapshots,iteration_rows=summaries,records=records,tail_periods=tail)

def check_stored() -> None:
    # Hash/shape/tuple/certificate inspection only. Never call expected,
    # pixels_for, round_away or Fraction from this HDL-stage entry point.
    seal=json.loads((ROOT/'SOURCE_SEAL.json').read_text())
    plan=json.loads((ROOT/'PREPARATION_PLAN.json').read_text())
    fixture_hashes={name:digest for name,digest in seal['files'].items() if name.startswith('fixtures/')}
    names={'fixtures/'+name for name in plan['fixture_files']}
    actual_names={p.relative_to(ROOT).as_posix() for p in (ROOT/'fixtures').rglob('*') if p.is_file()}
    if set(fixture_hashes)!=names or actual_names!=names: raise AssertionError('stored fixture inventory')
    for name,digest in fixture_hashes.items():
        if hashlib.sha256((ROOT/name).read_bytes()).hexdigest()!=digest: raise AssertionError(name)
    table=json.loads((ROOT/'CASE_TABLE.json').read_text())
    certificates=json.loads((ROOT/'BOUNDARY_CERTIFICATES.json').read_text())
    cases=reset_cases=0
    for profile in table['profiles']:
        directory=ROOT/'fixtures'/profile['name']
        programs=[('expected',profile['cases'])]
        if profile['reset_probes']:
            programs.extend((name,[table[name]]) for name in ['reset_old','reset_fresh'])
        for name,recipes in programs:
            stored=json.loads((directory/(name+'.json')).read_text())
            if len(stored)!=len(recipes): raise AssertionError('stored case count')
            if name=='expected': cases+=len(stored)
            else: reset_cases+=len(stored)
            lines=[str(len(stored))];n=profile['width']*profile['height']
            for ordinal,(case,recipe) in enumerate(zip(stored,recipes)):
                if (case['id'],case['ordinal'],case['k'],case['iterations'])!=(recipe['id'],ordinal,recipe['k'],recipe['iterations']):
                    raise AssertionError('stored recipe identity')
                if len(case['pixels'])!=n or len(case['markers'])!=n or any(type(v)!=int or not 0<=v<=255 for v in case['pixels']):
                    raise AssertionError('stored input shape')
                if any(len(row)!=3 or any(v not in [0,1] for v in row) for row in case['markers']): raise AssertionError('stored markers')
                if len(case['coefficients']) not in [0,256] or any(type(v)!=int or not 0<=v<=256 for v in case['coefficients']): raise AssertionError('stored coefficient shape')
                if any(len(row)!=n or any(type(v)!=int or not 0<=v<=65280 for v in row) for row in case['snapshots']): raise AssertionError('stored snapshot shape')
                if len(case['iteration_rows'])!=len(case['snapshots']) or any(len(row)!=5 for row in case['iteration_rows']): raise AssertionError('stored iteration shape')
                if len(case['records'])!=(1 if case['errors'] else n) or any(len(row)!=10 or any(type(v)!=int for v in row) for row in case['records']): raise AssertionError('stored response tuple shape')
                snapshots=[v for row in case['snapshots'] for v in row]
                lines.append(' '.join(map(str,[case['ordinal'],case['k'],case['iterations'],case['tag'],len(case['records']),case['errors'],len(snapshots),len(case['coefficients']),case['tail_periods']])))
                lines.extend(' '.join(map(str,[pixel]+marker)) for pixel,marker in zip(case['pixels'],case['markers']))
                lines.extend(map(str,case['coefficients']));lines.extend(map(str,snapshots))
                lines.extend(' '.join(map(str,row)) for row in case['records'])
                if profile['name']==certificates['signed_half']['profile'] and case['id']==certificates['signed_half']['case']:
                    cert=certificates['signed_half']
                    if case['coefficients'][cert['index']]!=cert['coefficient'] or any(case['snapshots'][0][i]!=cert['next_q8_at_both'] or case['records'][i][2]!=cert['final_pixel_at_both'] for i in cert['interior_indices']): raise AssertionError('stored signed-half certificate')
                if name=='reset_fresh':
                    cert=certificates['fresh_constant']
                    if case['iterations']!=cert['iterations'] or any(v!=cert['pixel'] for v in case['pixels']) or any(v!=cert['initial_q8'] for v in snapshots) or any(row[2:4]!=[cert['every_output_pixel'],cert['every_output_q8']] for row in case['records']): raise AssertionError('stored fresh certificate')
            text_name='vectors' if name=='expected' else name
            if (directory/(text_name+'.txt')).read_bytes()!=('\n'.join(lines)+'\n').encode('ascii'): raise AssertionError('stored JSON/text tuples')
    if len(table['profiles'])!=5 or cases!=16 or reset_cases!=2: raise AssertionError('stored fixed counts')
    print(f'STORED_HASH_SHAPE_TUPLES profiles=5 cases={cases} reset_cases=2 NO_MODEL_REEXECUTION')

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--check-stored',action='store_true',required=True)
    parser.parse_args();check_stored()
