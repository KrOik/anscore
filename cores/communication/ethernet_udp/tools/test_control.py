"""Real UDP->RMII->FCS->IPv4/UDP round-trip with exact application bytes."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir());P=ROOT/'cores/communication/ethernet_udp'


def main():
    out=ROOT/'artifacts/ethernet_udp_25k'/datetime.now(timezone.utc).strftime('control_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    sources=sorted((P/'rtl').glob('*.v'))+[P/'tb/tb_udp_control.v',ROOT/'projects/net_av_hdmi_20k/src/av_rmii_rx.v',ROOT/'cores/system/stream_bus_library/rtl/sys_timestamp64.v',ROOT/'cores/system/stream_bus_library/rtl/sys_atomic_config.v']
    report=dict(status='FAIL',physical_measurement=False,sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
                for p in sources+[Path(__file__).resolve()]})
    print('Evidence='+str(out),flush=True)
    try:
        exe=out/'test.vvp'
        for label,command in [('compile',['iverilog','-g2012','-s','tb_udp_control','-o',str(exe)]+list(map(str,sources))),('run',['vvp',str(exe)])]:
            r=subprocess.run(command,cwd=ROOT,capture_output=True,text=True,timeout=60)
            (out/(label+'.log')).write_text(r.stdout+r.stderr)
            if r.returncode:raise RuntimeError('\n'.join((r.stdout+r.stderr).splitlines()[-12:]))
        import zlib
        rows=re.findall(r'CSR_WORD run=(\d+) address=(\d+) value=(\d+)',r.stdout)
        for run,packets,length,seed in [(100,3,37,0x12345678),(101,2,7,0x87654321)]:
            words={int(a):int(v) for n,a,v in rows if int(n)==run}
            data=bytearray()
            for packet in range(packets):
                data.extend((packet>>(8*n))&255 if n<4 else ((seed&255)+(packet&255)*17+(n&255)*29)&255 for n in range(length))
            crc=zlib.crc32(data)
            expected={0x80:run,0x84:0,0x8c:packets,0x90:packets,0x94:len(data),0x98:len(data),0x9c:crc,0xa0:crc}
            if any(words.get(a)!=v for a,v in expected.items()) or not words.get(0x88,0):
                raise RuntimeError('actual CSR counter/CRC mismatch')
        if 'PASS UDP CSR atomic' not in r.stdout:raise RuntimeError('missing completion')
        report.update(status='PASS',successful_runs=2,error_runs=1,
                      scope='actual CSR/atomic/RMII replay simulation; no25K physical/throughput claim')
        print('PASS UDP CSR:2exact counter/CRC runs,queued config,byte strobes,held results,invalid command')
    except Exception as exc:report['reason']=str(exc);raise
    finally:(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')


if __name__=='__main__':main()
