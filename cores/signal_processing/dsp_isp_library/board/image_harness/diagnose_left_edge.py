"""Describe a captured erosion mismatch without changing any expected values."""
import argparse,json,struct
from pathlib import Path
from protocol import bit_exact,oracle

def main():
 p=argparse.ArgumentParser();p.add_argument('case',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
 v=json.loads((a.case/'expected.json').read_text());b=v['bits'];c=v['config'];mask=(1<<b)-1
 assert (c>>2)&3==0 and (c>>5)&511==511 and not c&16,'full-mask grayscale erosion only'
 raw=(a.case/'decoded.bin').read_bytes();start=raw.index(b'IMR1');report=raw[start:start+276]
 tag,cfg,n,flags,inc,outc,cycles=struct.unpack('<IIBBBBI',report[4:20])
 assert (tag,cfg,n,flags,inc,outc)==(v['tag'],c,64,0,64,64)
 actual=list(struct.unpack('<64I',report[20:]));expected=oracle(b,c,v['words'],v['padding'])
 gray=[bit_exact(((w>>(2*b))&mask,(w>>b)&mask,w&mask),b,'709' if c&1 else '601',bool(c&2),'gray')[0] for w in v['words']]
 left_zero=[e&~mask if i%8==0 else e for i,e in enumerate(expected)]
 result=dict(status='DIAGNOSTIC_NOT_ROOT_CAUSE',source=str(a.case),cycles=cycles,
  gray_rows=[gray[i:i+8] for i in range(0,64,8)],
  mismatches=[dict(index=i,actual=x,expected=y) for i,(x,y) in enumerate(zip(actual,expected)) if x!=y],
  hypothetical_left_zero_match=actual==left_zero,
  note='An exact match to left-edge zero substitution is a behavioral signature, not evidence of where the zero was introduced.')
 a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2))
if __name__=='__main__':main()
