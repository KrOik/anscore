import tempfile,json
from pathlib import Path
from run_tests import HERE,RTL,execute,hashes
def main():
 frozen=hashes();rows=[]
 for w,h in [(0,1),(1,0),(257,1),(1,257)]:
  with tempfile.TemporaryDirectory(prefix='bmp_encode_param_') as tmp:
   d=Path(tmp)
   tb='''module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,start_valid=0;
wire start_ready,done_valid,done_error;wire[7:0]error_code;
bmp_encoder #(.WIDTH(WW),.HEIGHT(HH))dut(.clk(clk),.rst_n(rst_n),.ce(1'b1),.start_valid(start_valid),.abort(1'b0),.cfg_top_down(1'b0),.start_ready(start_ready),.s_pixel(24'b0),.s_valid(1'b0),.s_sof(1'b0),.s_eol(1'b0),.s_last(1'b0),.m_ready(1'b1),.done_ready(1'b0),.done_valid(done_valid),.done_error(done_error),.error_code(error_code));
initial begin #21;rst_n=1;#10;start_valid=1;#10;start_valid=0;#10;
if(!done_valid||!done_error||error_code!=1)$fatal(1,"invalid parameters");$display("PASS invalid parameter");$finish;end
endmodule'''.replace('WW',str(w)).replace('HH',str(h))
   (d/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',d/'a.vvp',RTL,d/'tb.sv'],HERE,d/'c.log');out=execute(['vvp',d/'a.vvp'],HERE,d/'s.log');assert 'PASS invalid' in out
  rows.append(dict(width=w,height=h,error=1))
 assert hashes()==frozen
 (HERE/'parameter_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,cases=rows),indent=2)+'\n');print('PASS 4 invalid parameters')
if __name__=='__main__':main()
