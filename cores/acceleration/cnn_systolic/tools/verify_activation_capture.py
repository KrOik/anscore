"""Verify ALT1 raw activation scans, requiring all 32 address blocks."""
import argparse
import json
import re
from pathlib import Path

def frame(block):
    return b'ALT1'+bytes([block,0])+bytes(min(block*256+i,255) for i in range(256))

def verify(data):
    size=262
    start=data.find(b'ALT1')
    if not 0 <= start < size or len(data)<start+size:
        raise ValueError('Missing complete frame synchronization')
    first=data[start+4]
    if first>=32:
        raise ValueError('Invalid block index')
    if start and data[:start]!=frame((first-1)%32)[-start:]:
        raise ValueError('Corrupt leading fragment')
    pos,count,seen=start,0,set()
    while pos+size<=len(data):
        block=(first+count)%32
        if data[pos:pos+size]!=frame(block):
            raise ValueError(f'Frame {count}: expected block {block}, payload or status mismatch')
        seen.add(block)
        count+=1
        pos+=size
    if len(seen)!=32:
        raise ValueError('Capture does not cover all 8192 addresses')
    if data[pos:]!=frame((first+count)%32)[:len(data)-pos]:
        raise ValueError('Corrupt trailing fragment')
    return dict(status='PASS',complete_blocks=count,unique_addresses=8192,
                raw_bytes_checked=count*256,leading_bytes=start,trailing_bytes=len(data)-pos)

def self_test():
    stream=b''.join(frame(i%32) for i in range(96))
    for offset in range(262):
        verify(stream[offset:offset+262*34])
    bad_cases=[stream[:262*31],frame(0)*40,stream[:100]+stream[101:]]
    for index in (4,5,6,261,262*20+10):
        bad=bytearray(stream);bad[index]^=1;bad_cases.append(bytes(bad))
    for bad in bad_cases:
        try:verify(bad)
        except ValueError:pass
        else:raise AssertionError('Corrupt/incomplete scan accepted')

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('annotations',nargs='?',type=Path)
    p.add_argument('--self-test',action='store_true')
    a=p.parse_args()
    if a.self_test:
        self_test();print('PASS ALT1 verifier: 262 offsets, corruption/drop/order/coverage checks')
        if a.annotations is None:return
    if a.annotations is None:p.error('annotations required')
    data=bytearray()
    for line in a.annotations.read_text(encoding='utf-8-sig').splitlines():
        if line.startswith('uart-1: '):
            token=line[8:].strip()
            if not re.fullmatch('[0-9a-fA-F]{2}',token):raise ValueError('Expected hex annotations')
            data.append(int(token,16))
    a.annotations.with_suffix('.bin').write_bytes(data)
    try:result=verify(bytes(data))
    except ValueError as exc:
        a.annotations.with_suffix('.verdict.json').write_text(json.dumps(dict(status='FAIL',reason=str(exc))))
        raise
    a.annotations.with_suffix('.verdict.json').write_text(json.dumps(result,indent=2))
    print(json.dumps(result))

if __name__=='__main__':main()
