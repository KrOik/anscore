"""Real UDP->RMII->FCS->IPv4/UDP round-trip with exact application bytes."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir());P=ROOT/'cores/communication/ethernet_udp'


def main():
    out=ROOT/'artifacts/ethernet_udp_25k'/datetime.now(timezone.utc).strftime('loopback_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    sources=sorted((P/'rtl').glob('*.v'))+[P/'tb/tb_udp_loopback.v',ROOT/'projects/net_av_hdmi_20k/src/av_rmii_rx.v',ROOT/'cores/system/stream_bus_library/rtl/sys_timestamp64.v']
    report=dict(status='FAIL',physical_measurement=False,sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
                for p in sources+[Path(__file__).resolve()]})
    print('Evidence='+str(out),flush=True)
    try:
        exe=out/'test.vvp'
        for label,command in [('compile',['iverilog','-g2012','-s','tb_udp_loopback','-o',str(exe)]+list(map(str,sources))),('run',['vvp',str(exe)])]:
            r=subprocess.run(command,cwd=ROOT,capture_output=True,text=True,timeout=60)
            (out/(label+'.log')).write_text(r.stdout+r.stderr)
            if r.returncode:raise RuntimeError('\n'.join((r.stdout+r.stderr).splitlines()[-12:]))
        actual=[tuple(map(int,row)) for row in re.findall(r'LOOP_BYTE packet=(\d+) index=(\d+) data=(\d+) keep=(\d+) last=(\d+)',r.stdout)]
        expected=[]
        for packet,size in enumerate([0,1,2,7,63,1472,33]):
            if size==0:expected.append((packet,0,0,0,1))
            else:expected.extend((packet,n,(n*29+size)&255,1,int(n==size-1)) for n in range(size))
        if actual!=expected or 'PASS UDP loopback' not in r.stdout:
            raise RuntimeError('round-trip byte/keep/boundary mismatch')
        report.update(status='PASS',good_packets=7,error_completions=4,payload_bytes=1578,
                      scope='common50MHz RMII digital loopback,randomsinkstalls,posterrorrecovery; not25K/physicalPHY/line-rate')
        print('PASS UDP/RMII full loopback:7packets,1578exact payload bytes,4errors/recovery,randomstalls')
    except Exception as exc:report['reason']=str(exc);raise
    finally:(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')


if __name__=='__main__':main()
