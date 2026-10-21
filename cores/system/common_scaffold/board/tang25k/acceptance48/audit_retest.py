"""Read-only evidence audit; writes new JSON/Markdown reports, never run records.

Usage: python -B audit_retest.py restored_jtag_retest_YYYYMMDD_HHMMSS.json
A round is bounded by its filename start and the next round filename start.
Exactly one board record per candidate/attempt must lie in that interval.
"""
import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path
import re
import sys
import uuid
sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]
PASS = 'FUNCTIONAL_BOARD_PASS_HOLD_UNPROVEN'
ROUND = re.compile(r'restored_jtag_retest_(\d{8}_\d{6})\.json$')

def read(path):
    return json.loads(path.read_text(encoding='utf-8'))

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def require(condition, message):
    if not condition:
        raise ValueError(message)

def inside(base, name):
    path = (base / name).resolve()
    require(path.is_relative_to(base.resolve()), 'path escapes boundary: '+str(name))
    return path

def audit(run_path):
    match = ROUND.fullmatch(run_path.name)
    require(match is not None, 'invalid round filename')
    start = match[1]
    starts = sorted(m[1] for p in HERE.glob('restored_jtag_retest_*.json')
                    if (m := ROUND.fullmatch(p.name)) and m[1] > start)
    stop = starts[0] if starts else None
    run = read(run_path)
    require(run.get('status') == PASS, 'round is not completed PASS')
    require(run.get('timing_signoff') == 'HOLD_UNPROVEN', 'unexpected timing status')
    entries = run['entries']
    expected = read(HERE/'acceptance_status.json')['entries']
    names = [e['module'] for e in entries]
    expected_names = [e['module'] for e in expected]
    require(len(entries) == len(set(names)) == 48, 'round must contain 48 unique entries')
    require(len(expected_names) == len(set(expected_names)) == 48 and set(names) == set(expected_names), 'public entry coverage mismatch')
    snapshot = read(HERE/'FINAL_PRODUCTION_SOURCE_SHA256.json')['files']
    require(len(snapshot) == run.get('source_hashes_verified') == 202, '202 production hashes required')
    for name, digest in snapshot.items():
        require(sha(inside(ROOT,name)) == digest, 'production hash mismatch: '+name)
    # Existing verifier only reads frozen inputs; it does not synthesize or access JTAG.
    sys.path.insert(0,str(HERE.parent))
    import resume_candidate_route_official as route
    rows = []
    for entry in entries:
        name = entry['module']
        require(entry.get('status') == PASS and entry.get('repetitions') == 3, name+': entry status/count')
        candidate = inside(HERE,entry['candidate'])
        attempt = entry['attempt']
        require(re.fullmatch(r'[A-Za-z0-9_-]{1,48}',attempt), name+': invalid attempt')
        pattern = re.compile(r'functional_board_'+re.escape(attempt)+r'_(\d{8}_\d{6})_(\d{6})\.json$')
        records = []
        for path in candidate.glob('functional_board_'+attempt+'_*.json'):
            m = pattern.fullmatch(path.name)
            if m and m[1] >= start and (stop is None or m[1] < stop):
                records.append(path)
        require(len(records) == 1, name+': expected exactly one board record in round window, found '+str(len(records)))
        path = records[0]
        board = read(path)
        completed = dt.datetime.fromisoformat(board['date']).strftime('%Y%m%d_%H%M%S')
        require(completed >= start and (stop is None or completed < stop), name+': completion outside round window')
        require(board.get('status') == PASS and board.get('timing_signoff') == 'NOT_QUALIFIED_HOLD_UNPROVEN', name+': board status')
        require(board.get('route_attempt') == attempt and board.get('device') == 'GW5A-LV25MG121NES' and board.get('clock_mhz') == 50, name+': board identity')
        require(board.get('programming') == 'volatile SRAM only', name+': programming mode')
        require(re.fullmatch(r'[0-9a-f]{64}',board.get('bitstream_sha256','')),name+': missing bitstream identity')
        case = read(candidate/'case.json')
        require(case['public_module'] == name, name+': public module binding')
        for n,digest in case['source_sha256'].items():
            require(sha(inside(candidate,n)) == digest, name+': case frozen input mismatch '+n)
        current = route.verify_simulation_gate(candidate)
        state = read(candidate/('route_'+attempt+'_status.json'))
        for key in ('source_sha256_verified','freeze_files_sha256_verified','build_status_sha256'):
            require(current.get(key) == state['simulation_provenance'].get(key),name+': simulation/route freeze mismatch '+key)
        frozen = set(current.get('source_sha256_verified',{})) | set(current.get('freeze_files_sha256_verified',{}))
        require({'case.json','expected_uart.txt','tang25k.cst'} <= frozen,name+': required freeze inputs missing')
        routed = inside(candidate,state['artifacts']['pnr'])
        require(sha(routed) == board['routed_sha256'],name+': routed hash mismatch')
        summary = read(candidate/('build_'+attempt+'_summary.json'))
        require(summary.get('routed_json') == routed.name and summary.get('routed_json_sha256') == board['routed_sha256'],name+': route summary mismatch')
        require(sha(candidate/'top25k.json') == state['input_top25k_sha256'] == summary.get('input_top25k_sha256'),name+': synthesized input mismatch')
        require(sha(inside(candidate,state['artifacts']['cst'])) == state['derived_cst_sha256'],name+': constraints mismatch')
        require(sha(Path(state['chipdb'])) == state['chipdb_sha256'],name+': chip database mismatch')
        retained_image = candidate/('functional_'+attempt+'.fs')
        if retained_image.exists():
            require(sha(retained_image) == board['bitstream_sha256'],name+': retained bitstream hash mismatch')
        report = state['route_report']
        required = ('route_process','route_complete','lut4_device_gate','dff_device_gate','bsram_device_gate','mult12_device_gate','lut_15k','dsp_4','timing_50mhz')
        require(all(report['gates'].get(k) is True for k in required),name+': route/resource/setup gate')
        require(all(v for k,v in report['gates'].items() if k not in {'hold','hold_model_qualification'}),name+': other route gate')
        require(not report['hold_violation_lines'] and not any(s<0 for s in report['hold_slacks_ns']),name+': reported hold violation')
        expected_bytes = (candidate/'expected_uart.txt').read_bytes()
        require(re.fullmatch(rb'A48 [0-9A-F]{8} PASS E=00000000 D=[0-9A-F]{8} T=0\r\n',expected_bytes),name+': invalid expected result')
        runs, detects = board['runs'],board['jtag_detection']
        require(len(runs) == len(detects) == 3,name+': board repetition count')
        for i,(actual,detect) in enumerate(zip(runs,detects)):
            require(actual.get('index') == i and actual.get('status') == 'PASS' and actual.get('programmer_returncode') == 0,name+': programming status')
            require('Load SRAM' in actual.get('stdout',''),name+': missing SRAM programming log')
            require(actual.get('uart_hex') == actual.get('expected_hex') == expected_bytes.hex(),name+': exact UART mismatch')
            require(detect.get('returncode') == 0 and re.search(r'(?i)idcode\s+0x0*1281b\b',detect.get('stdout','')+detect.get('stderr','')),name+': JTAG identity')
        rows.append(dict(module=name,record=path.relative_to(HERE).as_posix(),record_sha256=sha(path),repetitions=3,exact_uart_matches=3,status=PASS))
    return dict(status='AUDIT_PASS',timing_signoff='HOLD_UNPROVEN',run=run_path.name,run_sha256=sha(run_path),round_start=start,round_stop_exclusive=stop,production_hashes_verified=202,entries_verified=48,exact_uart_matches=144,entries=rows,scope='Frozen bounded functional fixtures; no hold timing, full-resolution video, image quality or extension-library board signoff.')

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run',type=Path)
    args=parser.parse_args()
    run=args.run.resolve()
    require(run.parent == HERE,'run must be in acceptance48 directory')
    try:
        result=audit(run)
    except Exception as error:
        result=dict(status='AUDIT_FAIL',run=run.name,error=str(error))
    result['audited_utc']=dt.datetime.now(dt.timezone.utc).isoformat()
    stem=HERE/('audit_'+run.stem+'_'+dt.datetime.now().strftime('%Y%m%d_%H%M%S')+'_'+uuid.uuid4().hex[:8])
    json_path=stem.with_suffix('.json');md_path=stem.with_suffix('.md')
    with json_path.open('x',encoding='utf-8') as f:json.dump(result,f,indent=2);f.write('\n')
    lines=['# Independent board acceptance audit','',result['status'],'',f"Run: [{run.name}]({run.name})",'']
    if result['status']=='AUDIT_PASS':
        lines += ['48 unique entries; 144 actual SRAM programming / exact UART matches; 202 production hashes verified.','',result['scope'],'','| Module | Repetitions | Board record |','|---|---:|---|']
        lines += [f"| {e['module']} | 3 | [record]({e['record']}) |" for e in result['entries']]
    else:lines += [result['error']]
    with md_path.open('x',encoding='utf-8') as f:f.write('\n'.join(lines)+'\n')
    print(result['status'],json_path,md_path)
    return 0 if result['status']=='AUDIT_PASS' else 1
if __name__=='__main__':sys.exit(main())
