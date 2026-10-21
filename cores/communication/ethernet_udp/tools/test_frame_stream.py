"""Verify FCS-qualified frame stream under stalls and bank exhaustion."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())


def main():
    names = ['projects/net_av_hdmi_20k/src/av_rmii_rx.v',
             'cores/system/stream_bus_library/rtl/sys_timestamp64.v',
             'cores/communication/ethernet_udp/rtl/rmii_frame_stream.v',
             'cores/communication/ethernet_udp/tb/tb_rmii_frame_stream.v']
    out = ROOT/'artifacts/ethernet_udp_25k'/datetime.now(timezone.utc).strftime('frame_stream_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    hashes = {n: hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in names}
    hashes[str(Path(__file__).resolve().relative_to(ROOT))] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    snap = out/'source_snapshot'
    for name, digest in hashes.items():
        dest = snap/name;dest.parent.mkdir(parents=True, exist_ok=True);shutil.copyfile(ROOT/name, dest)
        if hashlib.sha256(dest.read_bytes()).hexdigest() != digest:
            raise RuntimeError('input changed during freeze')
    report = dict(status='FAIL', sources=hashes, physical_measurement=False,
                  scope='RMII50MHz digital simulation; not25K board or generic UDP')
    print('Evidence='+str(out), flush=True)
    try:
        exe = out/'test.vvp'
        for label, command in [('compile', ['iverilog', '-g2012', '-s', 'tb_rmii_frame_stream', '-o', str(exe)] + names),
                               ('run', ['vvp', str(exe)])]:
            r = subprocess.run(command, cwd=snap, capture_output=True, text=True, timeout=60)
            (out/(label+'.log')).write_text(r.stdout+r.stderr)
            if r.returncode:
                raise RuntimeError(r.stdout+r.stderr)
        if 'PASS RMII frame stream' not in r.stdout:
            raise RuntimeError('completion missing')
        import re
        rows = re.findall(r'FRAME_BYTE frame=(\d+) index=(\d+) data=(\d+) last=(\d+)',r.stdout)
        expected=[]
        for frame,(length,seed) in enumerate([(60,3),(257,9),(1514,23),(60,41),(61,57),(64,81)]):
            expected.extend((frame,n,(seed+n*17)&255,int(n==length-1)) for n in range(length))
        if [tuple(map(int,row)) for row in rows] != expected:
            raise RuntimeError('independent byte/order/boundary mismatch')
        report.update(status='PASS',delivered_frames=6,delivered_bytes=len(expected),
                      scope='whole Ethernet frame stream; UDP parser/TX/25K physical acceptance pending')
        print('PASS RMII frame stream:2016exact bytes,6frames,randomstalls,overflow/FCS/recovery')
    except Exception as exc:
        report['reason'] = str(exc)
        raise
    finally:
        (out/'summary.json').write_text(json.dumps(report, indent=2)+'\n')


if __name__ == '__main__':
    main()
