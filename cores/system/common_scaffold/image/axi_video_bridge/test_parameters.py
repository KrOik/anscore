from run_tests import *
from test_protocol import E,D,COMMON
def main():
 frozen=hashes();rows=[]
 for direction,original_dut in enumerate([E,D]):
  for w,h,dw in [(0,2,24),(4097,2,24),(3,0,24),(3,4097,24),(3,2,0),(3,2,65)]:
   dut=original_dut.replace('.WIDTH(3),.HEIGHT(2)',f'.WIDTH({w}),.HEIGHT({h}),.DATA_WIDTH({dw})')
   decl=COMMON[:COMMON.index('integer i,j')].replace('@DIR@',str(direction)).replace('@DUT@',dut)
   tb=decl+'''initial begin #12;rst_n=1;start_valid=1;#30;if(!done_valid||!frame_error||error_code!=1)$fatal(1,"invalid static");$display("PASS");$finish;end endmodule'''
   with tempfile.TemporaryDirectory(prefix='axi_video_parameters_') as tmp:
    p=Path(tmp);(p/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*SOURCES,p/'tb.sv'],p,p/'compile.log');execute(['vvp',p/'sim'],p,p/'run.log')
   rows.append(dict(direction=direction,width=w,height=h,data_width=dw,status='PASS'))
 assert hashes()==frozen
 (HERE/'parameter_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,cases=rows),indent=2)+'\n');print('PASS 12 invalid static profiles')
if __name__=='__main__':main()
