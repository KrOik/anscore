"""Strict stored-tuple transcript parser. No model, cut sum, overlap or optimizer."""
# SPDX-License-Identifier: Apache-2.0
from __future__ import annotations
import json
from pathlib import Path
import re


def validate(data: bytes, slot: dict, copies: Path) -> dict:
    assert b'\x00' not in data and data.endswith(b'\n')
    normalized = data.replace(b'\r\n',b'\n')
    assert b'\r' not in normalized, 'bare carriage return'
    lines = normalized.decode('ascii','strict').splitlines()
    certificates = json.loads((copies/'prepared/CERTIFICATES.json').read_bytes())
    spec = json.loads((copies/'fixtures/cases.json').read_bytes())
    assert certificates['schema'] == 'anscore-transport-stored-certificates-v1'
    cases = {c['id']:c for c in certificates['cases']}
    profile = next(p for p in spec['profiles'] if p['name'] == slot['profile'])
    mode = slot['mode']
    expected = [f"START {profile['name']} {mode}"]
    counts = dict(IN=0,OUT=0,HOLD=0,OFFER=0,PROBE=0,RESET=0,BEGIN=0,END=0,GAP=0)

    def line(kind: str, *fields) -> None:
        expected.append(' '.join(map(str,(kind,)+fields)))
        counts[kind] += 1

    def inputs(phase: int, case: dict, tag: int, rows: int) -> None:
        for i,row in enumerate(case['inputs'][:rows]):
            line('IN',phase,case['id'],i,*row,(tag+i) % (1 << profile['TAG']))

    def token(kind: str, phase: int, case: dict, ordinal: int, tag: int) -> None:
        row = case['tokens'][ordinal]
        assert len(row) == 13
        line(kind,phase,case['id'],ordinal,*row[:12],tag)

    def complete(phase: int, case: dict, tag: int, stalled: bool, successor=None) -> None:
        line('BEGIN',phase,case['id'],tag)
        inputs(phase,case,tag,profile['B'])
        if stalled:
            counts['GAP'] += 2*sum(i % 3 == 1 for i in range(profile['B']))
        if successor is not None:
            line('OFFER',successor['id'],*successor['inputs'][0],successor['tag'])
        for ordinal,row in enumerate(case['tokens']):
            if stalled and (ordinal == 0 or ordinal == len(case['tokens'])-1):
                for _ in range(3): token('HOLD',phase,case,ordinal,tag)
            token('OUT',phase,case,ordinal,tag)
        line('END',phase,case['id'])

    if mode in ('base','stall'):
        for i,identifier in enumerate(profile['ids']):
            successor = cases[profile['ids'][i+1]] if mode == 'stall' and i+1 < len(profile['ids']) else None
            complete(0,cases[identifier],cases[identifier]['tag'],mode == 'stall',successor)
    else:
        assert mode == 'reset'
        reset = next(r for r in spec['reset_jobs'] if r['name'] == slot['name'])
        aborted,fresh = cases[reset['abort_id']],cases[reset['fresh_id']]
        for point,tag in enumerate(reset['fresh_tags']):
            line('BEGIN',1,aborted['id'],aborted['tag'])
            accepted = 1 if point == 0 else profile['B']
            inputs(1,aborted,aborted['tag'],accepted)
            retired = len(aborted['tokens'])-1 if point == 3 else 0
            for ordinal in range(retired): token('OUT',1,aborted,ordinal,aborted['tag'])
            if point in (2,3):
                ordinal = 0 if point == 2 else len(aborted['tokens'])-1
                for _ in range(3): token('HOLD',1,aborted,ordinal,aborted['tag'])
            state = (1,10,12,16)[point]
            bit = 0 if point == 0 else (profile['C']//2 if point == 1 else profile['C']-1)
            line('PROBE',point,aborted['id'],accepted,retired,state,bit)
            for edge in range(3): line('RESET',point,edge)
            complete(2,fresh,tag,False)
    assert counts == slot['expected_tuples'], (counts,slot['expected_tuples'])
    expected.append('COUNTS '+' '.join(str(counts[k]) for k in ('IN','OUT','HOLD','OFFER','PROBE','RESET','BEGIN','END','GAP')))
    expected += [f"PASS TRANSPORT {profile['name']} {mode}",'FINISH TRANSPORT']
    assert len(lines) == len(expected)+1, 'unexpected or missing raw lines'
    assert lines[:-1] == expected, 'raw input/output/hold/reset/offer tuple mismatch'
    assert re.fullmatch(r'(?:[^\r\n]*[/\\])?sim[/\\]tb_transport\.sv:[1-9][0-9]*: \$finish called at [0-9]+ \(1ps\)',lines[-1]), 'unexpected finish grammar'
    return counts
