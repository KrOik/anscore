"""Check SHA/CRC selftest or full-rate SHA captures against independent models."""
import argparse
import json
import re
from pathlib import Path
from golden_model import compute
from sha256_board_model import LENGTHS,expected_records

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
    raise SystemExit('FAIL: hardware reported failure')
if args.full_rate:
    expected=''.join(expected_records())
    frames=[]
    for line in text.splitlines(keepends=True):
        if line.startswith('SHA27') and line.endswith('\n'):
            match=re.fullmatch(r'SHA27 PASS N=0C ([0-9A-F]{816})\n',line)
            if not match or match[1]!=expected:
                raise SystemExit('FAIL: full-rate digest, cycles, count or frame format')
            frames.append(match[1])
    if not frames:
        raise SystemExit('FAIL: no complete full-rate frame')
    result=dict(status='PASS',complete_frames=len(frames),messages_per_frame=12,
                digest_bytes_per_frame=384,message_lengths=LENGTHS,
                cycles_per_message=[int(row[:4],16) for row in expected_records()],
                scope='27 MHz internal full-rate stimulus; all digests and cycle counts checked')
else:
    golden=compute()['digests']
    required=['CRYPT M=001F P=001F','U0 AESB S D=811C9DC5']
    for i,name in enumerate(('SHAB','CRC8','CR16','CR32'),start=1):
        required.append(f'U{i} {name} P D={golden[name]:08X}')
    counts={line:text.count(line) for line in required}
    if not all(counts.values()):
        raise SystemExit('FAIL: missing SHA/CRC digest: '+str(counts))
    result=dict(status='PASS',reports=counts,scope='SHA+CRC mask 0x1e; AES disabled')
(out/'board_verdict.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result))
