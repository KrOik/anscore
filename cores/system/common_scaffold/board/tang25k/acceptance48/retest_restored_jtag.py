"""Repeat frozen 48-entry functional acceptance after local JTAG recovery."""
import datetime
import hashlib
import json
from pathlib import Path
import functional_board

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]

def read(path):
    return json.loads(path.read_text(encoding='utf-8'))

def main():
    stamp = datetime.datetime.now().strftime('%Y%m%d_%H%M%S')
    record = HERE / ('restored_jtag_retest_' + stamp + '.json')
    result = dict(status='RUNNING', entries=[], timing_signoff='HOLD_UNPROVEN')
    def save():
        record.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    snapshot = read(HERE / 'FINAL_PRODUCTION_SOURCE_SHA256.json')['files']
    for name, digest in snapshot.items():
        if hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != digest:
            raise RuntimeError('Production source changed: ' + name)
    result['source_hashes_verified'] = len(snapshot)
    save()
    try:
        for entry in read(HERE / 'acceptance_status.json')['entries']:
            choices = []
            for case in entry['cases']:
                if case['status'] != 'FUNCTIONAL_BOARD_PASS_HOLD_UNPROVEN' or case['candidate_changes_pending_integration']:
                    continue
                for board in case['board']:
                    if board['status'] == 'FUNCTIONAL_BOARD_PASS_HOLD_UNPROVEN':
                        evidence = read(HERE / board['path'])
                        choices.append((evidence.get('date', ''), case, evidence))
            _, case, evidence = max(choices, key=lambda item: item[0])
            candidate = HERE / case['path']
            attempt = evidence['route_attempt']
            image = candidate / ('functional_' + attempt + '.fs')
            existed = image.exists()
            print('BEGIN', entry['module'], flush=True)
            functional_board.run(candidate, attempt, 'COM44', 3)
            # Only remove a newly generated image bound to this successful run.
            if not existed and image.exists():
                digest = functional_board.route.sha256_file(image)
                records = list(candidate.glob('functional_board_' + attempt + '*.json'))
                matches = [read(p) for p in records]
                if not any(r.get('status') == 'FUNCTIONAL_BOARD_PASS_HOLD_UNPROVEN' and r.get('bitstream_sha256') == digest for r in matches):
                    raise RuntimeError('Cleanup provenance missing')
                image.unlink()
            result['entries'].append(dict(module=entry['module'], candidate=str(candidate.relative_to(HERE)), attempt=attempt, repetitions=3, status='FUNCTIONAL_BOARD_PASS_HOLD_UNPROVEN'))
            save()
            print('PROGRESS', len(result['entries']), '/48', flush=True)
        result['status'] = 'FUNCTIONAL_BOARD_PASS_HOLD_UNPROVEN'
    except Exception as error:
        result['status'] = 'FAIL'
        result['error'] = str(error)
        raise
    finally:
        save()
        print('REPORT', record, flush=True)

if __name__ == '__main__':
    main()
