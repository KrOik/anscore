"""Legal maximum single-axis sizes and repeated checksum wraparound."""
import json
from run_tests import HERE,hashes,run_case
def main():
 frozen=hashes();rows=[]
 for w,h,mode in [(4096,1,0),(1,4096,1),(257,86,1)]:
  row=run_case('axis_or_checksum_limit',w,h,mode,[0xffffff]*(w*h));rows.append(row);print(row,flush=True)
 assert hashes()==frozen
 (HERE/'numeric_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,cases=rows),indent=2)+'\n')
if __name__=='__main__':main()
