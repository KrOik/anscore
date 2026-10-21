"""Real UDP->RMII->FCS->IPv4/UDP round-trip with exact application bytes."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir());P=ROOT/'cores/communication/ethernet_udp'


def main():
    out=ROOT/'artifacts/ethernet_udp_25k'/datetime.now(timezone.utc).strftime('replay_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    sources=sorted((P/'rtl').glob('*.v'))+[P/'tb/tb_udp_replay.v',ROOT/'projects/net_av_hdmi_20k/src/av_rmii_rx.v',ROOT/'cores/system/stream_bus_library/rtl/sys_timestamp64.v']
    report=dict(status='FAIL',physical_measurement=False,sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
                for p in sources+[Path(__file__).resolve()]})
    print('Evidence='+str(out),flush=True)
    try:
        exe=out/'test.vvp'
        for label,command in [('compile',['iverilog','-g2012','-s','tb_udp_replay','-o',str(exe)]+list(map(str,sources))),('run',['vvp',str(exe)])]:
            r=subprocess.run(command,cwd=ROOT,capture_output=True,text=True,timeout=60)
            (out/(label+'.log')).write_text(r.stdout+r.stderr)
            if r.returncode:raise RuntimeError('\n'.join((r.stdout+r.stderr).splitlines()[-12:]))
        import zlib
        rows=re.findall(r'REPLAY run=(\d+) packets=(\d+) length=(\d+) seed=(\d+) cycles=(\d+) crc=(\d+)',r.stdout)
        if len(rows)!=4:raise RuntimeError('missing successful runs')
        for run,packets,length,seed,cycles,crc in rows:
            packets,length,seed,cycles,crc=map(int,(packets,length,seed,cycles,crc))
            data=bytearray()
            for packet in range(packets):
                data.extend((packet>>(8*n))&255 if n<4 else ((seed&255)+(packet&255)*17+(n&255)*29)&255 for n in range(length))
            if zlib.crc32(data)!=crc or cycles<=0:raise RuntimeError('independent replay CRC/cycles')
        if 'PASS finite UDP replay' not in r.stdout:raise RuntimeError('missing completion')
        report.update(status='PASS',successful_runs=4,error_runs=4,
                      scope='synthesizable digital RMII replay owner simulation; no25K physical/throughput claim')
        print('PASS finite UDP replay:4exact CRC runs,4errors,exact timeout,abort/reset recovery,latched config,heldresults')
    except Exception as exc:report['reason']=str(exc);raise
    finally:(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')


if __name__=='__main__':main()
