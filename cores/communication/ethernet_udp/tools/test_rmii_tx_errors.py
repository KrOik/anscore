"""Exact independent EthernetII/IPv4/UDP transmit encoder comparison."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
from test_udp_rx import checksum

ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir());P=ROOT/'cores/communication/ethernet_udp'


def encode(size):
    data=bytes((n*29+size)&255 for n in range(size))
    src=bytes([192,168,137,15]);dst=bytes([192,168,137,1])
    udp=struct.pack('!HHHH',11452,9000,size+8,0)+data
    c=checksum(src+dst+b'\0\x11'+struct.pack('!H',len(udp))+udp) or 65535
    udp=udp[:6]+struct.pack('!H',c)+udp[8:]
    ip=struct.pack('!BBHHHBBH4s4s',0x45,0,len(udp)+20,0x1234,0x4000,64,17,0,src,dst)
    ip=ip[:10]+struct.pack('!H',checksum(ip))+ip[12:]
    frame=bytes.fromhex('84ba591684c20600aabb0cdd0800')+ip+udp
    return frame+b'\0'*max(0,60-len(frame))


def main():
    out=ROOT/'artifacts/ethernet_udp_25k'/datetime.now(timezone.utc).strftime('rmii_tx_errors_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    sources=[P/'rtl/rmii_frame_tx.v',P/'tb/tb_rmii_tx_errors.v']
    report=dict(status='FAIL',physical_measurement=False,sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
                  for p in sources+[Path(__file__).resolve(),P/'tools/test_udp_rx.py']})
    print('Evidence='+str(out),flush=True)
    try:
        exe=out/'test.vvp'
        for label,command in [('compile',['iverilog','-g2012','-s','tb_rmii_tx_errors','-o',str(exe)]+list(map(str,sources))),('run',['vvp',str(exe)])]:
            r=subprocess.run(command,cwd=ROOT,capture_output=True,text=True,timeout=60)
            (out/(label+'.log')).write_text(r.stdout+r.stderr)
            if r.returncode:raise RuntimeError('\n'.join((r.stdout+r.stderr).splitlines()[-12:]))
        rows=[tuple(map(int,x)) for x in re.findall(r'WIRE_BYTE case=(\d+) index=(\d+) data=(\d+)',r.stdout)]
        expected=[]
        for case,size,seed in [(0,60,3),(7,64,7)]:
            import zlib
            body=bytes((seed+n*17)&255 for n in range(size))
            frame=b'\x55'*7+b'\xd5'+body+struct.pack('<I',zlib.crc32(body))
            (out/f'frame{case}.bin').write_bytes(frame)
            expected.extend((case,n,b) for n,b in enumerate(frame))
        if rows!=expected or 'PASS RMII serializer' not in r.stdout:
            raise RuntimeError('TX byte/header/checksum/boundary mismatch')
        report.update(status='PASS',good_packets=2,error_completions=5,exact_frame_bytes=len(expected),
                      scope='RMII bit-level TX simulation; physical acceptance pending')
        print('PASS RMII serializer:2exact frames,5rejections,drain/reset/recovery,heldcompletion')
    except Exception as exc:report['reason']=str(exc);raise
    finally:(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')


if __name__=='__main__':main()
