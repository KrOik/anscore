"""Recheck retained simulation payloads and emit quantitative pixel/marker errors."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path

ROOT = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())


def compare(actual, expected):
    if len(actual) != len(expected) or len(actual) % 4:
        raise ValueError(f'payload lengths/record alignment: {len(actual)}/{len(expected)}')
    errors = [abs(a-b) for a,b in zip(actual[::4], expected[::4])]
    metadata = sum(actual[i:i+4][1:] != expected[i:i+4][1:] for i in range(0,len(actual),4))
    return dict(pixels=len(errors), pixel_mismatches=sum(e != 0 for e in errors),
                max_absolute_error=max(errors, default=0),
                mean_absolute_error=sum(errors)/len(errors) if errors else 0,
                metadata_record_mismatches=metadata)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('evidence', type=Path)
    parser.add_argument('--kind', choices=('all_modes','realtime'), required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    report = dict(status='FAIL', physical_measurement=False, kind=args.kind,
                  evidence=str(args.evidence.resolve()),
                  generated_utc=datetime.now(timezone.utc).isoformat(),
                  verifier_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    try:
        summary_file = args.evidence/'summary.json'
        summary = json.loads(summary_file.read_text())
        report['summary_sha256'] = hashlib.sha256(summary_file.read_bytes()).hexdigest()
        if summary['status'] != 'PASS':
            raise ValueError('input evidence is not terminal PASS')
        if not summary.get('sources'):
            raise ValueError('missing source provenance')
        for name, digest in summary['sources'].items():
            if hashlib.sha256((ROOT/name).read_bytes()).hexdigest() != digest:
                raise ValueError('current source differs: '+name)
        expected = bytearray()
        if args.kind == 'all_modes':
            from test_all_modes import golden_frame
            for mode in range(64):
                expected += golden_frame(mode)[0]
        else:
            from test_realtime import golden_frame
            for w,h,n in ((320,240,3),(640,480,2)):
                for frame in range(n):
                    expected += golden_frame(w,h,frame)[0]
        actual = (args.evidence/'pixels.bin').read_bytes()
        if hashlib.sha256(actual).hexdigest() != summary['output_sha256']:
            raise ValueError('retained payload hash differs from tested payload')
        report.update(compare(actual, expected))
        if not report['pixels'] or report['pixel_mismatches'] or report['metadata_record_mismatches']:
            raise ValueError('numeric/metadata comparison failed')
        report['status'] = 'PASS'
    except Exception as exc:
        report['reason'] = str(exc)
        raise
    finally:
        (args.output/'error_report.json').write_text(json.dumps(report, indent=2)+'\n')
        print(json.dumps(report))


if __name__ == '__main__':
    main()
