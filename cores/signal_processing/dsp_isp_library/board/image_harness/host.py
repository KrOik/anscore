"""Prepare fresh external frames / verify complete decoded bytes. No device access."""
import argparse,json,pathlib,secrets
from protocol import make_packet,oracle,verify
p=argparse.ArgumentParser();sub=p.add_subparsers(dest='cmd',required=True)
m=sub.add_parser('prepare');m.add_argument('--bits',type=int,choices=(8,10),required=True);m.add_argument('--config',type=lambda s:int(s,0),required=True);m.add_argument('--padding',type=int,choices=(0,1),default=1);m.add_argument('--stall',type=int,choices=range(8),default=0);m.add_argument('--output',type=pathlib.Path,required=True)
v=sub.add_parser('verify');v.add_argument('--expected',type=pathlib.Path,required=True);v.add_argument('--decoded',type=pathlib.Path,required=True)
a=p.parse_args()
if a.cmd=='prepare':
 a.output.mkdir(parents=True,exist_ok=False);tag=secrets.randbits(32);words=[secrets.randbits(3*a.bits) for _ in range(64)]
 result=oracle(a.bits,a.config,words,a.padding)
 (a.output/'request.bin').write_bytes(make_packet(tag,a.config,words,a.stall))
 (a.output/'expected.json').write_text(json.dumps(dict(tag=tag,bits=a.bits,config=a.config,padding=a.padding,stall=a.stall,words=words,outputs=result),indent=2));print(a.output)
else:
 e=json.loads(a.expected.read_text());r=verify(a.decoded.read_bytes(),e['tag'],e['config'],e['words'],e['bits'],e['stall'],e['padding']);print(json.dumps(r,indent=2))
