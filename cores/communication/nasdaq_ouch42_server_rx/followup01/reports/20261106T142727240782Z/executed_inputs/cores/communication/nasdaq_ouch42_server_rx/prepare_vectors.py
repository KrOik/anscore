"""SPDX-License-Identifier: Apache-2.0. Finite deterministic preparation only.

Execution is forbidden until root and independent peer exact-source approval.
"""
from pathlib import Path
import argparse,hashlib,json
from reference.model import decode,samples


def core_cases():
    base=samples(); cases=list(base)
    for data in base:
        cases.extend(data[:n] for n in range(1,len(data)))
        cases.append(data+b'!')
    cases.extend(bytes([kind]) for kind in range(256) if kind not in b'SAUCEJ')
    for value in range(256):
        if value not in b'SE': cases.append(base[0][:9]+bytes([value]))
    for index in (1,2):
        for offset in (23,64):
            for value in range(256):
                data=bytearray(base[index]);data[offset]=value;cases.append(bytes(data))
    for index,offset in ((3,27),(5,23),(4,31)):
        for value in range(256):
            data=bytearray(base[index]);data[offset]=value;cases.append(bytes(data))
    # Opaque identifiers / alpha bytes and unrestricted unsigned integer extrema.
    for index in (1,2):
        data=bytearray(base[index]);data[9:23]=bytes(14);data[28:36]=bytes([255])*8
        data[44:48]=bytes([0,128,254,255]);cases.append(bytes(data))
    data=bytearray(base[1]);data[1:9]=bytes(8);data[24:28]=bytes(4)
    data[36:44]=bytes(8);data[49:57]=bytes(8);data[59:63]=bytes(4);cases.append(bytes(data))
    data=bytearray(base[4]);data[1:9]=bytes([255])*8;data[23:31]=bytes(8)
    data[32:40]=bytes([255])*8;cases.append(bytes(data))
    for size in (65535,65536,70000): cases.append(b'A'+bytes(size-1))
    assert len(cases)==2557
    return cases


def integration_cases(depth):
    result=[];session=b'SESSION001';logged=closed=faulted=exhausted=0;next_seq=0
    def add(kind,payload=b'',reset=False,start=None,force=None):
        nonlocal logged,closed,faulted,exhausted,next_seq,session
        if reset:
            logged=closed=faulted=exhausted=0;next_seq=0;session=bytes(10)
        status=0;sequence=0;reason=0;event=0;otype=ostatus=olen=is_ouch=0
        length=1+len(payload)
        if kind==b'A':
            session=b'SESSION001';next_seq=1 if start is None else start;logged=1
            payload=session+str(next_seq).rjust(20).encode();length=31
        elif kind==b'J':
            reason=payload[0];closed=1
        elif kind==b'S':
            if length>depth: status=3;faulted=1
            elif not logged: status=5;faulted=1
            elif exhausted: status=6;faulted=1
            else:
                sequence=next_seq
                if next_seq==(1<<64)-1: exhausted=1
                else: next_seq+=1
                d=decode(payload);is_ouch=1
                otype,ostatus,olen,event=d['type'],d['status'],d['length'],d['event']
        elif kind==b'Z': logged=0;closed=1
        elif kind not in (b'+',b'H'): status=1;faulted=1
        if force is not None: status=force;faulted=1
        wire=length.to_bytes(2,'big')+kind+payload
        result.append(dict(reset=int(reset),wire=wire,soup_status=status,soup_type=kind[0],
            soup_reason=reason,soup_length=length,sequence=sequence,next=next_seq,
            session=int.from_bytes(session,'big'),logged=logged,closed=closed,faulted=faulted,
            exhausted=exhausted,is_ouch=is_ouch,ouch_status=ostatus,ouch_type=otype,
            ouch_length=olen,event=event))
    add(b'+',b'debug-before-login',reset=True)
    add(b'A')
    for data in samples(): add(b'S',data)
    add(b'H');add(b'+',b'seq unchanged');add(b'S')
    for data in samples(): add(b'S',data[:-1])
    add(b'S',b'B'+bytes(31))
    bad=bytearray(samples()[1]);bad[23]=0;add(b'S',bytes(bad))
    add(b'H');add(b'Z')
    add(b'S',samples()[0],reset=True)
    add(b'A',reset=True,start=(1<<64)-1)
    add(b'S',samples()[4]);add(b'H');add(b'S',samples()[0])
    add(b'A',reset=True);add(b'S',b'A'+bytes(depth-1))
    add(b'J',b'A',reset=True)
    assert len(result)==29
    return result


def main():
    ap=argparse.ArgumentParser();ap.add_argument('--out',required=True);args=ap.parse_args()
    out=Path(args.out);out.mkdir(parents=True,exist_ok=False)
    receipt=dict(core={},integration={})
    cases=core_cases()
    for tag in (1,8,32):
        p=out/('core_t'+str(tag)+'.txt'); mask=(1<<tag)-1
        with p.open('w',encoding='ascii',newline='\n') as f:
            for i,data in enumerate(cases):
                d=decode(data);owner=(i*73+17)&mask
                f.write(f"{len(data)} {d['status']} {d['type']:02x} {owner:x} {d['event']:0180x}\n")
                f.write(' '.join(f'{x:02x}' for x in data)+'\n')
        receipt['core'][str(tag)]=dict(cases=len(cases),bytes=sum(map(len,cases)),
            sha256=hashlib.sha256(p.read_bytes()).hexdigest())
    order=('reset','soup_status','soup_type','soup_reason','soup_length','sequence','next',
           'session','logged','closed','faulted','exhausted','is_ouch','ouch_status',
           'ouch_type','ouch_length','event')
    for depth,tag in ((128,8),(4096,32)):
        cases_i=integration_cases(depth);p=out/f'soup_d{depth}_t{tag}.txt'
        with p.open('w',encoding='ascii',newline='\n') as f:
            for i,case in enumerate(cases_i):
                f.write(f"{len(case['wire'])} {(i*73+17)&((1<<tag)-1):x} "+
                        ' '.join(f'{case[k]:x}' for k in order)+'\n')
                f.write(' '.join(f'{x:02x}' for x in case['wire'])+'\n')
        receipt['integration'][f'{depth}_{tag}']=dict(cases=len(cases_i),
            bytes=sum(len(c['wire']) for c in cases_i),sha256=hashlib.sha256(p.read_bytes()).hexdigest())
    (out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8')
    print('B46_A_PREP_PASS core_cases=2557 soup_cases=29 profiles=5')


if __name__=='__main__': main()
