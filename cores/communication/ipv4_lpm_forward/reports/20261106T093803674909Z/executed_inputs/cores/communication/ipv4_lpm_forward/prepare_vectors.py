"""SPDX-License-Identifier: Apache-2.0. One isolated import and vector preparation."""
import argparse,hashlib,json,sys
from pathlib import Path
sys.dont_write_bytecode=True
import reference_model as oracle

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--routes',type=int,required=True)
    parser.add_argument('--tag',type=int,required=True);parser.add_argument('--example',action='store_true')
    parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
    rows=oracle.build(args.routes,args.tag,args.example)
    raw=(str(len(rows))+'\n'+''.join(map(oracle.serialize,rows))).encode()
    with args.output.open('xb') as f:f.write(raw)
    counts={'vectors':len(rows),'vector_cfg':sum(r[0]==0 for r in rows),
            'vector_packets':sum(r[0] in (1,3) for r in rows),'vector_resets':sum(r[0]==2 for r in rows),
            'faults':sum(r[0]==3 for r in rows)}
    if args.example:
        expected={k:v*2 for k,v in counts.items()}
        expected.update(epochs=2,resets=3,cancelled=1,recovery=1,accepted=counts['vector_packets']*2+2,outputs=counts['vector_packets']*2+1)
    else:
        fc=sum(i%3==0 and r[0]!=2 for i,r in enumerate(rows))
        fp=sum(i%3==1 and r[0]!=2 for i,r in enumerate(rows))
        expected=dict(counts,N=args.routes,T=args.tag,future_configs=fc,future_packets=fp,futures=fc+fp,
                      resets=9+counts['vector_resets'],reset_cases=4,priority_checks=1,
                      cfg_accepts=counts['vector_cfg']+fc+10,cfg_results=counts['vector_cfg']+fc+9,
                      packet_accepts=counts['vector_packets']+fp+8,packet_results=counts['vector_packets']+fp+5)
    data={'parameters':{'routes':args.routes,'tag':args.tag,'example':args.example},'counts':counts,'expected_runtime':expected,
          'vector_bytes':len(raw),'vector_sha256':hashlib.sha256(raw).hexdigest(),'oracle_imports':1,'planning_oracle_calls':0,
          'oracle_source_path':str(Path(oracle.__file__).resolve()),'oracle_source_sha256':hashlib.sha256(Path(oracle.__file__).read_bytes()).hexdigest()}
    with args.output.with_suffix('.summary.json').open('x',encoding='utf-8',newline='\n') as f:json.dump(data,f,indent=2);f.write('\n')
    print('PASS prepare_ipv4_lpm '+' '.join(f'{k}={v}' for k,v in counts.items()))

if __name__=='__main__':main()
