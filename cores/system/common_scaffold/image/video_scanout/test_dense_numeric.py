from test_timing import *
from test_scanout import TB as STB
def execute_tb(tb,prefix):
 with tempfile.TemporaryDirectory(prefix=prefix) as tmp:
  p=Path(tmp);(p/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*SOURCES,p/'tb.sv'],p,p/'compile.log');out=execute(['vvp',p/'sim'],p,p/'run.log',timeout=300);print(out,flush=True);return out
def main():
 frozen=hashes();rows=[]
 for w,h,dense in [(64,32,True),(4096,1,True),(1,4096,False)]:
  tb=STB.replace('@W@',str(w)).replace('@H@',str(h))
  if dense:tb=tb.replace('pixel_tick=cyc%3==0;ce=cyc%7<4;','pixel_tick=1;ce=1;').replace('||off==0','')
  out=execute_tb(tb,'scanout_dense_');rows.append(dict(module='video_rgb_scanout',width=w,height=h,full_rate=dense,frames=2,pixels=2*w*h,output=out))
 values=dict(HA=1,HF=65533,HS=1,HB=0,VA=1,VF=0,VS=1,VB=0,HP=1,VP=0);tb=TB
 for k,v in values.items():tb=tb.replace('@'+k+'@',str(v))
 tb=tb.replace('video_timing_generator dut','video_timing_generator #(.MAX_TOTAL(65535)) dut');out=execute_tb(tb,'timing_max_total_');rows.append(dict(module='video_timing_generator',horizontal_total=65535,frames=2,output=out))
 assert hashes()==frozen
 (HERE/'dense_numeric_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,cases=rows),indent=2)+'\n')
if __name__=='__main__':main()
