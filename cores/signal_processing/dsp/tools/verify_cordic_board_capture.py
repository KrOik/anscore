"""Verify CORDIC full-rate or complete DSP selftest UART annotations."""
import argparse
import json
import re
from pathlib import Path
from golden_model import cordic, digest, stream_crdr, stream_crdv, stream_dds, stream_fir, stream_pid

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('annotations',type=Path)
parser.add_argument('--full-rate',action='store_true')
args=parser.parse_args()
parts=[]
for line in args.annotations.read_text(encoding='utf-8-sig').splitlines():
    if line.startswith('uart-1: '):
        token=line[len('uart-1: '):]
        parts.append({'[0D]':'\r','[0A]':'\n'}.get(token,token))
text=''.join(parts)
out=args.annotations.parent
(out/'board_uart.txt').write_text(text,encoding='ascii',newline='')
if 'FAIL' in text or re.search(r'U[0-4] \w+\s+F D=',text):
    raise SystemExit('FAIL: board reported failure')
if args.full_rate:
    expected=[]
    for i in range(32):
        x,y,z=cordic(i*1024-16384,i*733-12000,i*2000-31000,i&1)
        expected.append(f'{((z&0x3ffff)<<32)|((y&65535)<<16)|(x&65535):016X}')
    frames=[]
    for line in text.splitlines(keepends=True):
        if line.startswith('CORD27') and line.endswith('\n'):
            match=re.fullmatch(r'CORD27 PASS N=20 L=11 ([0-9A-F]{512})\n',line)
            if not match or match[1]!=''.join(expected):
                raise SystemExit('FAIL: malformed report, count, latency or sample data mismatch')
            frames.append(match[1])
    if not frames:
        raise SystemExit('FAIL: no complete full-rate report')
    result=dict(status='PASS',complete_frames=len(frames),samples_per_frame=32,
                bytes_per_frame=256,port_latency_cycles=17,output_interval_cycles=1,
                modes=2,scope='internal stream at 27 MHz, all x/y/z values checked')
else:
    required=['DSP5 M=001F P=001F']
    for i,(name,stream) in enumerate(zip(('CRDR','CRDV','DDS ','FIR ','PID '),
                                        (stream_crdr,stream_crdv,stream_dds,stream_fir,stream_pid))):
        required.append(f'U{i} {name} P D={digest(stream()):08X}')
    counts={line:text.count(line) for line in required}
    if not all(counts.values()):
        raise SystemExit('FAIL: missing DSP digest: '+str(counts))
    result=dict(status='PASS',reports=counts,scope='all five original DSP selftests')
(out/'board_verdict.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result))
