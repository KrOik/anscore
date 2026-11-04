#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""One frozen finite matrix; explicit pre-HDL seal and terminal evidence."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
PLAN_HASH = '3929bca5b9187e1a9e9462d763075a2ed8e1b4764895bb1541c0a1acfd5ad480'


def encoded(value):
    return (json.dumps(value, sort_keys=True, indent=2)+'\n').encode('utf-8')


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def files():
    return sorted(p for p in ROOT.rglob('*') if p.is_file() and
                  p.name not in ['SOURCE_FREEZE.json','verification.json'] and
                  'failure_archive' not in p.relative_to(ROOT).parts)


def source_map():
    result = {}
    for path in files():
        raw = path.read_bytes()
        raw.decode('utf-8', 'strict')
        assert b'\r' not in raw and not raw.startswith(b'\xef\xbb\xbf'), path
        result[path.relative_to(ROOT).as_posix()] = sha(raw)
    return result


def plan_and_fixtures():
    raw = (ROOT/'TEST_PLAN.json').read_bytes()
    assert sha(raw) == PLAN_HASH, 'Frozen plan changed'
    plan = json.loads(raw)
    assert len(plan['children']) == 24
    assert all(x['timeout_seconds'] == 20 for x in plan['children'])
    assert sha((ROOT/'prepare.py').read_bytes()) == plan['prepare_sha256']
    models = []
    for profile in plan['profiles']:
        for name, item in profile['fixtures'].items():
            data = (ROOT/name).read_bytes()
            assert sha(data) == item['sha256'] and len(data) == item['bytes']
        model = json.loads((ROOT/f'vectors/{profile["id"]}.json').read_bytes())
        assert model['profile'] == profile['parameters']
        assert len(model['main']) == profile['main_frames']
        assert [r['target_id'] for r in model['resets']] == [r['target_id'] for r in profile['resets']]
        models.append(model)
    return plan, models


def seal():
    assert not (ROOT/'SOURCE_FREEZE.json').exists(), 'Seal already exists'
    assert not (ROOT/'verification.json').exists(), 'An attempt already exists'
    plan, _ = plan_and_fixtures()
    record = dict(schema='anscore.b24.byte_write_coalescer.freeze.v1',
                  before_first_hdl_tool=True, plan_sha256=PLAN_HASH,
                  baseline=plan['baseline'], source_sha256=source_map())
    raw = encoded(record)
    (ROOT/'SOURCE_FREEZE.json').write_bytes(raw)
    print(json.dumps(dict(status='PRE_HDL_SEALED', source_freeze_sha256=sha(raw),
                          files=len(record['source_sha256']), plan_sha256=PLAN_HASH)))


def parse_profile(stdout, profile, model):
    n, a, b, t = profile['parameters']
    main = model['main']
    complete = main+[r['fresh'] for r in model['resets']]
    all_frames = complete+[r['candidate'] for r in model['resets']]
    by_id = {f['id']: f for f in all_frames}
    actual_results = []
    valid = {}
    writes = {f['id']: [] for f in all_frames}
    acks = {f['id']: [] for f in all_frames}
    observations = []
    summary = None
    for line in stdout.splitlines():
        fields = line.split()
        if fields[0] == 'WRITE':
            ident, index = map(int, fields[1:3])
            assert ident in by_id and index == len(writes[ident])
            writes[ident].append(tuple(int(x,16) for x in fields[3:6]))
        elif fields[0] == 'ACK':
            ident, index, error = map(int,fields[1:])
            assert ident in by_id and index == len(acks[ident])
            acks[ident].append(error)
        elif fields[0] == 'VALID':
            ident, status = map(int,fields[1:3])
            assert ident in by_id and ident not in valid
            valid[ident] = (status,int(fields[3],16),int(fields[4]),int(fields[5],16),int(fields[6]))
        elif fields[0] == 'RESULT':
            ident, status = map(int,fields[1:3])
            actual_results.append((ident,status,int(fields[3],16),int(fields[4]),
                                   int(fields[5],16),*[int(x) for x in fields[6:]]))
        elif fields[0] == 'OBS':
            observations.append(tuple(map(int,fields[1:])))
        elif fields[0] == 'PASS':
            assert summary is None
            summary = dict(re.findall(r'(\w+)=(\S+)', line))
        else:
            raise AssertionError(('Unexpected simulator output', line))
    expected_results = []
    for f in complete:
        e = f['expected']
        expected_results.append((f['id'],e['status'],e['tag'],e['count'],e['error_mask'],
                                 e['latency'],e['ram_reads'],e['ram_writes'],len(f['tokens'])))
    assert actual_results == expected_results, 'Full retired result sequence'
    expected_valid_ids = {f['id'] for f in complete}
    expected_valid_ids.update(r['candidate']['id'] for r in model['resets'] if r['target_id'] in [21,22])
    assert set(valid) == expected_valid_ids
    for ident, result in valid.items():
        e = by_id[ident]['expected']
        assert result == (e['status'],e['tag'],e['count'],e['error_mask'],e['latency'])
    for ident, f in by_id.items():
        qs = [(q['addr'],q['data'],q['strobe']) for q in f['requests']]
        es = [q['error'] for q in f['requests']]
        assert writes[ident] == qs[:len(writes[ident])]
        assert acks[ident] == es[:len(acks[ident])]
        assert len(acks[ident]) <= len(writes[ident]) <= len(acks[ident])+1
        if ident in {x['id'] for x in complete}:
            assert len(writes[ident]) == len(qs) == len(acks[ident])
    assert [x[0] for x in observations] == [x['target_id'] for x in model['resets']]
    obs_reads = obs_writes = obs_inputs = obs_qholds = obs_pwaits = 0
    cap = min(n,(1 << a)//b)
    middle = (cap-1)//2
    for obs, reset in zip(observations, model['resets']):
        target, state, scan, out, accepted, rd, wr, issued, acked, qhold, phold = obs
        f = reset['candidate']
        state_expected = {0:0,1:1,2:4,3:4,4:2,5:2,6:2,7:3,8:3,9:3,
                          10:5,11:5,12:6,13:7,14:7,15:7,16:8,17:8,
                          18:9,19:9,20:9,21:10,22:10,23:1,24:1,25:1}[target]
        assert state == state_expected
        if target in [4,5,6,7,8,9,10,11]:
            assert scan == (middle if target in [5,8] else cap-1 if target in [6,9,11] else 0)
        if target in [13,14,15,16,17,18,19,20]:
            assert out == (middle if target == 14 else cap-1 if target in [15,17,19] else 1 if target == 20 else 0)
        assert 0 <= accepted <= len(f['tokens'])
        assert issued == len(writes[f['id']]) and acked == len(acks[f['id']])
        events = f['events'][:accepted]
        wanted_reads = sum(x['scan_reads'] for x in events)
        wanted_writes = sum(x['write_index'] >= 0 for x in events)
        if state in [2,3,4,5]:
            assert events
            wanted_reads -= events[-1]['scan_reads']
            wanted_reads += scan if state == 2 else scan+1 if state in [3,5] else events[-1]['scan_reads']
            wanted_writes -= events[-1]['write_index'] >= 0
        if state in [7,8,9,10]:
            wanted_reads += out if state == 7 else out+1 if state in [8,9] else f['expected']['count']
        assert (rd,wr) == (wanted_reads,wanted_writes), ('Canceled operation certificate',target,rd,wr,wanted_reads,wanted_writes)
        obs_reads += rd;obs_writes += wr;obs_inputs += accepted
        obs_qholds += sum(q['q_stall'] for q in f['requests'][:issued])+qhold
        obs_pwaits += sum(q['ack_delay'] for q in f['requests'][:acked])+phold
    assert summary and summary['profile'] == profile['id'] and summary['state_mask'] == '7ff'
    summary = {key:(value if key in ['profile','state_mask'] else int(value)) for key,value in summary.items()}
    expected_summary = dict(main=len(main),resets=len(model['resets']),results=len(complete),
                            inputs=sum(len(f['tokens']) for f in complete)+obs_inputs,
                            reads=sum(f['expected']['ram_reads'] for f in complete)+obs_reads,
                            writes=sum(f['expected']['ram_writes'] for f in complete)+obs_writes,
                            output_holds=4*len(complete)+3*sum(r['target_id'] in [21,22] for r in model['resets']),
                            q_holds=sum(q['q_stall'] for f in complete for q in f['requests'])+obs_qholds,
                            p_waits=sum(q['ack_delay'] for f in complete for q in f['requests'])+obs_pwaits,
                            queued=len(main)-1)
    for key,value in expected_summary.items():
        assert summary[key] == value, ('Summary',key,summary[key],value)
    assert summary['rows'] > 0 and summary['source_holds'] > 0
    summary.update(max_latency=max(result[-1] for result in valid.values()),
                   main_requests=sum(len(f['requests']) for f in main),
                   fresh_requests=sum(len(r['fresh']['requests']) for r in model['resets']),
                   first_valid_checks=len(valid), retired_result_checks=len(complete),
                   reset_ids=[x[0] for x in observations])
    return summary


def archive_failure(report, work):
    dest = ROOT/'failure_archive'/'attempt_01'
    assert not dest.exists(), 'No automatic second attempt'
    source = [p for p in ROOT.rglob('*') if p.is_file() and 'failure_archive' not in p.relative_to(ROOT).parts]
    hashes = {}
    for path in source:
        name = 'tested_source/'+path.relative_to(ROOT).as_posix()
        target = dest/name;target.parent.mkdir(parents=True,exist_ok=True)
        raw = path.read_bytes();target.write_bytes(raw);hashes[name] = sha(raw)
    for path in sorted(work.rglob('*')):
        if path.is_file():
            name = 'artifacts/'+path.relative_to(work).as_posix()
            target = dest/name;target.parent.mkdir(parents=True,exist_ok=True)
            raw = path.read_bytes();target.write_bytes(raw);hashes[name] = sha(raw)
    (dest/'archive.json').write_bytes(encoded(dict(status=report['status'], files_sha256=hashes,
                                                plan_sha256=PLAN_HASH, root_repair_authorization_required=True)))


def run():
    assert not (ROOT/'verification.json').exists(), 'Attempt already recorded; no rerun authorized'
    plan, models = plan_and_fixtures()
    freeze_raw = (ROOT/'SOURCE_FREEZE.json').read_bytes()
    freeze = json.loads(freeze_raw)
    assert freeze['source_sha256'] == source_map() and freeze['plan_sha256'] == PLAN_HASH
    suite = REPO/'tools'/'oss-cad-suite'/'oss-cad-suite'
    env = dict(os.environ)
    env['PATH'] = os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')])
    iv = os.environ.get('IVERILOG') or shutil.which('iverilog',path=env['PATH'])
    vv = os.environ.get('VVP') or shutil.which('vvp',path=env['PATH'])
    assert iv and vv, 'Local Icarus tools required'
    source = dict(freeze['source_sha256']);source['SOURCE_FREEZE.json'] = sha(freeze_raw)
    report = dict(schema='anscore.b24.byte_write_coalescer.receipt.v1',status='NOT_RUN',
                  baseline=plan['baseline'], plan_sha256=PLAN_HASH,source_freeze_sha256=sha(freeze_raw),
                  source_sha256=source,timeout_occurred=False,profiles=[],
                  not_run=plan['not_run'],children=[dict(x,status='NOT_RUN') for x in plan['children']])
    receipt = ROOT/'verification.json'
    def save():
        receipt.write_bytes(encoded(report))
    save()
    with tempfile.TemporaryDirectory(prefix='anscore_b24_coalescer_') as directory:
        work = Path(directory)
        current_exe = None
        try:
            for index, child in enumerate(plan['children']):
                if child['name'].endswith('_compile'):
                    current_exe = work/(child['name'].split('_')[0]+'.vvp')
                argv = [str(current_exe) if arg == '{exe}' else arg for arg in child['argv']]
                argv[0] = iv if argv[0] == 'iverilog' else vv
                record = report['children'][index]
                record['actual_argv'] = argv
                start = time.perf_counter()
                try:
                    result = subprocess.run(argv,cwd=ROOT,env=env,capture_output=True,timeout=20)
                except subprocess.TimeoutExpired as error:
                    decode = lambda x:(x or b'').decode('utf-8','replace')
                    record.update(status='TIMEOUT_NOT_RUN',stdout=decode(error.stdout),stderr=decode(error.stderr),
                                  elapsed_seconds=time.perf_counter()-start)
                    report['timeout_occurred'] = True
                    save()
                    raise
                stdout = result.stdout.decode('utf-8','replace')
                stderr = result.stderr.decode('utf-8','replace')
                good = (result.returncode > 0 and plan['negative_marker'] in stderr) if child['expected'] == 'EXPECTED_REJECT' else result.returncode == 0 and not stderr
                record.update(returncode=result.returncode,stdout=stdout,stderr=stderr,
                              elapsed_seconds=time.perf_counter()-start,
                              status=child['expected'] if good else 'FAIL')
                save()
                assert good, 'Child failed: '+child['name']
                if child['name'].endswith('_sim'):
                    pindex = int(child['name'][1:child['name'].index('_')])
                    report['profiles'].append(parse_profile(stdout,plan['profiles'][pindex],models[pindex]))
                    save()
            assert source_map() == freeze['source_sha256'], 'Source changed during attempt'
            report['status'] = 'PASS'
            keys = ['main','resets','results','inputs','reads','writes','rows','source_holds',
                    'output_holds','q_holds','p_waits','queued','main_requests','fresh_requests',
                    'first_valid_checks','retired_result_checks']
            report['totals'] = {key:sum(p[key] for p in report['profiles']) for key in keys}
            report['hardware'] = 'HW_UNVERIFIED'
            save()
            print(json.dumps(dict(status='PASS',totals=report['totals'],receipt_sha256=sha(receipt.read_bytes()))))
        except BaseException as error:
            report['status'] = 'TIMEOUT_NOT_RUN' if report['timeout_occurred'] else 'FAIL'
            report['error'] = type(error).__name__+': '+str(error)
            save();archive_failure(report,work)
            raise


if __name__ == '__main__':
    if sys.argv[1:] == ['--seal']:
        seal()
    elif not sys.argv[1:]:
        run()
    else:
        raise SystemExit('Use --seal exactly once before the single authorized matrix, then no arguments.')
