"""Future approved preparation only; imports the independent oracle once."""
from pathlib import Path
import argparse, hashlib, importlib.util, json

ROOT = Path(__file__).resolve().parent
PROFILES = ((32,1),(128,8),(4096,32))


def fixtures(depth):
    def packet(kind, data=b''):
        body = bytes([kind]) + data
        return len(body).to_bytes(2,'big') + body
    def login(number=1, text=None):
        return packet(65, b'  SESSION1' + (str(number).rjust(20).encode() if text is None else text))
    cases = []
    def add(wire, reset=False, future=False):
        cases.append((int(reset),wire,int(future)))
    add(packet(43,b'debug\x00\xff\n'),True)
    add(login())
    add(packet(83,b'\x00\x0a\xffSoup'),future=True)
    add(packet(83))
    add(packet(72))
    add(packet(43))
    add(packet(83,bytes((i*37+11)&255 for i in range(depth-1))),future=True)
    add(packet(90))
    add(login((1<<64)-2),True)
    add(packet(83,b'penultimate'))
    add(packet(83,b'last'))
    add(packet(72))
    add(packet(83,b'overflow'))
    for text in (b' '*20,b'0'*20,b' '*19+b'x',b' '*17+b'1 2',b'18446744073709551616',b' '*18+b'-1',b'1'+b' '*19):
        add(login(text=text),True)
    add(login(text=b'00000000000000000001'),True)
    add(packet(83,b'leading-zero-seed'))
    add(login())
    for wire in (packet(65,b'x'*29),packet(65,b'x'*31),packet(65),packet(72),packet(83),packet(90),
                 packet(74,b'A'),packet(74,b'S'),packet(74,b'X'),packet(74,b'AS'),
                 packet(72,b'x'),packet(90,b'x'),b'\x00\x00'):
        add(wire,True)
    for kind in b'ULRO?':
        add(packet(kind,b'bad-direction'),True)
    add(login(),True)
    add(packet(83,b'x'*depth))
    add(packet(43,b'x'*65534),True)
    add(login())
    add(packet(83,b'x'*65534))
    add(login(),True)
    add(packet(74,b'A'))
    return cases


def main(output):
    assert not output.exists()
    output.mkdir(parents=True)
    spec=importlib.util.spec_from_file_location('soup_independent_oracle',ROOT/'reference/model.py')
    model=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(model)
    profiles=[]
    for depth,tag_width in PROFILES:
        label=f'd{depth}_t{tag_width}'
        state=model.initial()
        counts=dict(cases=0,bytes=0,payload=0,future=0,vector_resets=0)
        lines=[]
        for index,(reset,wire,future) in enumerate(fixtures(depth)):
            if reset:
                state=model.initial(); counts['vector_resets']+=1
            tag=(index*73+19)&((1<<tag_width)-1)
            result,state=model.receive(wire,state,depth,tag)
            assert not future or (result['logged'] and not result['closed'] and not result['fault'])
            lines.append(f"{reset} {len(wire)} {result['status']} {result['type']:x} {result['length']} "
                f"{result['sequence']:x} {result['next']:x} {result['session']:x} {result['logged']} "
                f"{result['closed']} {result['fault']} {result['exhausted']} {tag:x} {result['reason']:x} "
                f"{len(result['payload'])} {future}")
            lines.extend(f'{byte:02x}' for byte in wire)
            lines.extend(f'{byte:02x}' for byte in result['payload'])
            counts['cases']+=1; counts['bytes']+=len(wire); counts['payload']+=len(result['payload'])
            counts['future']+=future
        data=('\n'.join(lines)+'\n').encode('ascii')
        path=output/(label+'.txt')
        path.write_bytes(data)
        profiles.append(dict(label=label,parameters=[depth,tag_width],counts=counts,path=path.name,
            sha256=hashlib.sha256(data).hexdigest(),bytes=len(data)))
    receipt=dict(schema='anscore-b45-soup-vectors-v1',oracle_imports=1,oracle_preparations=1,profiles=profiles)
    (output/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8',newline='\n')
    print('B45_A_PREP_PASS profiles=3 oracle_imports=1 oracle_preparations=1')


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--output',type=Path,required=True)
    main(parser.parse_args().output)
