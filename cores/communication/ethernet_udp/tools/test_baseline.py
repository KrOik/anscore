"""Audit canonical20K RMII/UDP reuse before25K stream integration."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())


def main():
    names = ['projects/net_av_hdmi_20k/src/av_rmii_rx.v',
             'projects/net_av_hdmi_20k/src/av_udp.v',
             'projects/net_av_hdmi_20k/src/av_async_fifo.v',
             'projects/net_av_hdmi_20k/sim/tb_av_udp.v']
    out = ROOT/'artifacts/ethernet_udp_25k'/datetime.now(timezone.utc).strftime('reuse_baseline_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    hashes = {n: hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in names}
    hashes[str(Path(__file__).resolve().relative_to(ROOT))] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    snap = out/'source_snapshot'
    for name, digest in hashes.items():
        dest = snap/name;dest.parent.mkdir(parents=True, exist_ok=True);shutil.copyfile(ROOT/name, dest)
        if hashlib.sha256(dest.read_bytes()).hexdigest() != digest:
            raise RuntimeError('input changed during freeze')
    report = dict(status='FAIL', sources=hashes, physical_measurement=False,
                  scope='unchanged20K canonical reuse baseline; not25K subsystem or physical PHY')
    print('Evidence='+str(out), flush=True)
    try:
        exe = out/'test.vvp'
        for label, command in [('compile', ['iverilog', '-g2012', '-s', 'tb_av_udp', '-o', str(exe)] + names),
                               ('run', ['vvp', str(exe)])]:
            r = subprocess.run(command, cwd=snap, capture_output=True, text=True, timeout=60)
            (out/(label+'.log')).write_text(r.stdout+r.stderr)
            if r.returncode:
                raise RuntimeError(r.stdout+r.stderr)
        if 'PASS RMII ARP/UDP/IP/FCS' not in r.stdout or 'bytes=7168' not in r.stdout:
            raise RuntimeError('baseline completion missing')
        report.update(status='PASS', delivered_bytes=7168,
                      cases=['ARP', 'START', 'UDP', 'Ethernet FCS', 'IPv4 checksum',
                             'async FIFO', 'duplicate', 'future sequence', 'credit exhaustion',
                             'retry after drain', 'debug cumulative CRC'])
        print(r.stdout.strip())
    except Exception as exc:
        report['reason'] = str(exc)
        raise
    finally:
        (out/'summary.json').write_text(json.dumps(report, indent=2)+'\n')


if __name__ == '__main__':
    main()
