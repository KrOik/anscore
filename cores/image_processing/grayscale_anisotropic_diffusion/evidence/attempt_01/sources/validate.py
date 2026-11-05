"""Strict ordered raw checks against stored expectations; no fixture mutation."""
from pathlib import Path
import re
from guards import ROOT,read

def case_lines(profile: str,case: dict,ordinal: int,prefix: str='') -> list[str]:
    rows=[]
    if case['coefficients']: rows.append(f'{prefix}TABLE {profile} {ordinal} 256 {sum(case["coefficients"])}')
    rows.extend(' '.join(map(str,[prefix+'ITER',profile,ordinal]+row)) for row in case['iteration_rows'])
    if prefix: return rows
    rows.append(f'TAIL {profile} {ordinal} {case["tail_periods"]}')
    rows.extend(' '.join(map(str,['REC',profile,ordinal]+row)) for row in case['records'])
    rows.append(' '.join(map(str,['FRAME',profile,ordinal,len(case['records']),case['errors'],case['tag'],sum(len(s) for s in case['snapshots'])])))
    return rows

def simulation(child: dict,raw: bytes,source_root: Path) -> dict:
    profile=child['profile'];directory=source_root/'fixtures'/profile
    lines=raw.decode('ascii').splitlines()
    if any(line.strip()!=line or '  ' in line for line in lines[:-1]): raise ValueError('noncanonical raw spacing')
    tb=(source_root/'sim/tb_grayscale_anisotropic_diffusion.sv').read_text().splitlines()
    finish_line=next(i+1 for i,line in enumerate(tb) if line.strip()=='$finish;')
    if not lines or not re.fullmatch(r'sim/tb_grayscale_anisotropic_diffusion\.sv:'+str(finish_line)+r': \$finish called at [0-9]+ \(1ps\)',lines[-1]): raise ValueError('exact finish absent')
    if child['mode']=='main':
        cases=read(directory/'expected.json');wanted=[]
        for ordinal,case in enumerate(cases): wanted+=case_lines(profile,case,ordinal)
        records=sum(len(c['records']) for c in cases);writes=sum(sum(len(s) for s in c['snapshots']) for c in cases)
        iterations=sum(len(c['snapshots']) for c in cases);tables=sum(bool(c['coefficients']) for c in cases)
        wanted.append(f'PASS MAIN profile={profile} stall={child["stall"]} frames={len(cases)} records={records} writes={writes} iterations={iterations} tables={tables}')
        if lines[:-1]!=wanted: raise ValueError('main exact ordered stream mismatch')
        return dict(frames=len(cases),records=records,writes=writes,iterations=iterations,tables=tables)
    old=read(directory/'reset_old.json')[0];fresh=read(directory/'reset_fresh.json')[0]
    probes=['capture_prefix','table_divide','flux_product','output_held'];position=0;observations=[]
    for ordinal,name in enumerate(probes):
        prefix=[]
        if name=='flux_product': prefix=case_lines(profile,dict(old,iteration_rows=[]),ordinal,'ABORT')
        if name=='output_held': prefix=case_lines(profile,old,ordinal,'ABORT')
        if lines[position:position+len(prefix)]!=prefix: raise ValueError('aborted prefix mismatch')
        position+=len(prefix);tokens=lines[position].split(' ');position+=1
        if len(tokens)!=13 or tokens[:4]!=['PROBE',profile,str(ordinal),name] or any(not re.fullmatch(r'[0-9]+',x) for x in tokens[4:]): raise ValueError('probe shape')
        values=list(map(int,tokens[4:]));sent,received,state,busy,step,pixel,iteration,direction,bank=values
        expected_state=[0,7,17,25][ordinal]
        if sent!=(1 if ordinal==0 else 12) or received!=0 or state!=expected_state or pixel!=0 or bank!=0: raise ValueError('probe ownership/state')
        if ordinal==0 and (busy,step,iteration,direction)!=(0,0,0,0): raise ValueError('capture probe')
        if ordinal==1 and (busy,step,iteration,direction)!=(1,7,0,0): raise ValueError('division probe')
        if ordinal==2 and (busy,step,iteration,direction)!=(0,23,0,3): raise ValueError('product probe')
        if ordinal==3 and (busy,step,iteration,direction)!=(0,23,2,3): raise ValueError('output probe')
        observations.append(dict(name=name,values=values))
        wanted=[f'RESETEDGE {profile} {ordinal} {edge}' for edge in range(3)]+case_lines(profile,fresh,ordinal)
        if lines[position:position+len(wanted)]!=wanted: raise ValueError('reset/fresh sequence')
        position+=len(wanted)
    if lines[position:-1]!=[f'PASS RESET profile={profile} probes=4 fresh_records=48 fresh_writes=96 old_writes=24 aborted_records=0 reset_edges=12']: raise ValueError('reset summary')
    return dict(probes=4,fresh_records=48,fresh_writes=96,old_writes=24,aborted_records=0,reset_edges=12,observations=observations)
