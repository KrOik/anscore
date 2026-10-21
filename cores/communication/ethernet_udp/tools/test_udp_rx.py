"""Independent IPv4/UDP encoder and exact RTL payload/error regression."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess

ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
P=ROOT/'cores/communication/ethernet_udp'


def checksum(data):
    data += b'\0'*(len(data)%2)
    total=sum(struct.unpack('!'+str(len(data)//2)+'H',data))
    while total>>16:
        total=(total&65535)+(total>>16)
    return (~total)&65535


def packet(payload, checked=True):
    src=bytes([192,168,137,1]);dst=bytes([192,168,137,15])
    udp=struct.pack('!HHHH',9000,11452,len(payload)+8,0)+payload
    if checked:
        c=checksum(src+dst+b'\0\x11'+struct.pack('!H',len(udp))+udp) or 65535
        udp=udp[:6]+struct.pack('!H',c)+udp[8:]
    ip=struct.pack('!BBHHHBBH4s4s',0x45,0,len(udp)+20,1,0x4000,64,17,0,src,dst)
    ip=ip[:10]+struct.pack('!H',checksum(ip))+ip[12:]
    frame=bytes.fromhex('0600aabb0cdd84ba591684c20800')+ip+udp
    return bytearray(frame+b'\0'*max(0,60-len(frame)))


def main():
    out=ROOT/'artifacts/ethernet_udp_25k'/datetime.now(timezone.utc).strftime('udp_rx_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    sources=[P/'rtl/udp_payload_rx.v',P/'tb/tb_udp_payload_rx.v']
    report=dict(status='FAIL',physical_measurement=False,sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
                for p in sources+[Path(__file__).resolve()]})
    print('Evidence='+str(out),flush=True)
    try:
        cases=[];expected=[]
        for n in [0,1,2,7,63,1472]:
            data=bytes((i*29+n)&255 for i in range(n))
            cases.append(packet(data));expected.append(data)
        data=bytes(range(33));cases.append(packet(data,False));expected.append(data)
        # Header errors are checked before checksum errors.
        for kind in ['ip','udp','port','fragment','length','truncate','mac']:
            f=packet(b'known payload')
            if kind=='ip':f[24]^=1
            elif kind=='udp':f[42]^=1
            elif kind=='port':f[37]^=1
            elif kind=='fragment':f[21]=1
            elif kind=='length':f[39]=7
            elif kind=='truncate':f=f[:40]
            elif kind=='mac':f[0]^=1
            cases.append(f);expected.append(None)
        values=[len(cases)]
        for frame in cases:values.extend([len(frame),*frame])
        fixture=out/'fixture.mem';fixture.write_text(''.join(f'{v:08x}\n' for v in values))
        (out/'expected.json').write_text(json.dumps([None if b is None else list(b) for b in expected]))
        exe=out/'test.vvp'
        for label,command in [('compile',['iverilog','-g2012','-s','tb_udp_payload_rx','-o',str(exe)]+list(map(str,sources))),
                              ('run',['vvp',str(exe),'+fixture='+str(fixture)])]:
            r=subprocess.run(command,cwd=ROOT,capture_output=True,text=True,timeout=60)
            (out/(label+'.log')).write_text(r.stdout+r.stderr)
            if r.returncode:raise RuntimeError(r.stdout+r.stderr)
        rows=[tuple(map(int,x)) for x in re.findall(r'UDP_BYTE case=(\d+) data=(\d+) keep=(\d+) last=(\d+)',r.stdout)]
        wanted=[]
        for i,data in enumerate(expected):
            if data is None:continue
            if not data:wanted.append((i,0,0,1))
            else:wanted.extend((i,b,1,int(j==len(data)-1)) for j,b in enumerate(data))
        if rows!=wanted:raise RuntimeError('payload/order/empty/boundary mismatch')
        if 'UDP_COUNTS good=7 header=5 ip=1 udp=1' not in r.stdout or 'PASS UDP payload receiver' not in r.stdout:
            raise RuntimeError('error accounting mismatch')
        report.update(status='PASS',good_packets=7,rejected_packets=7,payload_bytes=sum(len(x) for x in expected if x is not None),
                      cases='empty/odd/even/maxpayload,nonzero/zeroUDPchecksum,header/IP/UDPcorruption,randomgaps/stalls')
        print('PASS generic IPv4/UDP RX:7good/7rejected,checksums,empty/odd/maxpayload,randomstalls')
    except Exception as exc:
        report['reason']=str(exc);raise
    finally:(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')


if __name__=='__main__':main()
