from run_tests import *
def main():
 frozen=hashes();rows=[]
 for w,h,r in [(0,12,4),(4097,1,1),(1,0,1),(1,4097,1),(1,1,0),(1,1,4097)]:
  tb='''module tb;reg clk=0;always #5 clk=~clk;reg rst_n=0;wire done_valid,frame_error;wire[7:0]error_code;
  tiff_encoder #(.WIDTH(WW),.HEIGHT(HH),.ROWS_PER_STRIP(RR))dut(.clk(clk),.rst_n(rst_n),.ce(1'b1),.start_valid(1'b1),.cfg_mode(2'b0),.cfg_big_endian(1'b0),.abort(1'b0),.s_pixel(32'b0),.s_valid(1'b0),.s_sof(1'b0),.s_eol(1'b0),.s_last(1'b0),.m_ready(1'b1),.done_ready(1'b0),.done_valid(done_valid),.frame_error(frame_error),.error_code(error_code));
  initial begin #12;rst_n=1;#30;if(!done_valid||!frame_error||error_code!=1)$fatal(1,"static invalid");$display("PASS");$finish;end endmodule'''
  for k,v in dict(WW=w,HH=h,RR=r).items():tb=tb.replace(k,str(v))
  with tempfile.TemporaryDirectory(prefix='tiff_parameter_') as tmp:
   d=Path(tmp);(d/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',d/'sim',RTL,d/'tb.sv'],d,d/'compile.log');execute(['vvp',d/'sim'],d,d/'run.log')
  rows.append(dict(width=w,height=h,rows_per_strip=r,status='PASS'))
 assert hashes()==frozen
 (HERE/'parameter_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,cases=rows),indent=2)+'\n');print('PASS 6 invalid profiles')
if __name__=='__main__':main()
