from test_timing import *
from test_scanout import TB as STB
def main():
 frozen=hashes();rows=[]
 for module,params in [('timing','MAX_ACTIVE=0'),('timing','MAX_ACTIVE=4097'),('timing','MAX_TOTAL=0'),('timing','MAX_TOTAL=65536'),('scanout','FIFO_DEPTH=1'),('scanout','FIFO_DEPTH=4097'),('scanout','PREBUFFER=0'),('scanout','PREBUFFER=17')]:
  name,value=params.split('=')
  if module=='timing':
   tb=TB
   for k,v in dict(HA=4,HF=2,HS=1,HB=1,VA=2,VF=1,VS=1,VB=1,HP=0,VP=1).items():tb=tb.replace('@'+k+'@',str(v))
   tb=tb.replace('video_timing_generator dut',f'video_timing_generator #(.{name}({value})) dut')
  else:
   tb=STB.replace('@W@','4').replace('@H@','2');parameter=dict(FIFO_DEPTH=16,PREBUFFER=4);parameter[name]=int(value)
   tb=tb.replace('.FIFO_DEPTH(16),.PREBUFFER(4)',f'.FIFO_DEPTH({parameter["FIFO_DEPTH"]}),.PREBUFFER({parameter["PREBUFFER"]})')
  tb=tb[:tb.index('initial begin repeat')]+'''initial begin #12;rst_n=1;ce=1;start_valid=1;#80;if(!done_valid||!frame_error||error_code!=1||running)$fatal(1,"invalid static");$display("PASS");$finish;end endmodule'''
  with tempfile.TemporaryDirectory(prefix='scanout_parameter_') as tmp:
   p=Path(tmp);(p/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*SOURCES,p/'tb.sv'],p,p/'compile.log');execute(['vvp',p/'sim'],p,p/'run.log')
  rows.append(dict(module=module,parameter=params,status='PASS'))
 assert hashes()==frozen
 (HERE/'parameter_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,cases=rows),indent=2)+'\n');print('PASS 8 static profiles')
if __name__=='__main__':main()
