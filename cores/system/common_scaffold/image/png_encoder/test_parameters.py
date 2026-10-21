import tempfile,json
from pathlib import Path
from run_tests import HERE,RTL,hashes,execute
def main():
 frozen=hashes();rows=[]
 for w,h in [(0,12),(16,0),(4097,12),(16,4097)]:
  tb=f'''module tb;reg clk=0;always #5 clk=~clk;reg rst_n=0,start_valid=0;wire done,error;wire[7:0]code;
png_encoder #(.WIDTH({w}),.HEIGHT({h}))dut(.clk(clk),.rst_n(rst_n),.ce(1'b1),.start_valid(start_valid),
.cfg_mode(2'd0),.abort(1'b0),.s_pixel(24'd0),.s_valid(1'b0),.s_sof(1'b0),.s_eol(1'b0),.s_last(1'b0),
.m_ready(1'b1),.done_valid(done),.done_ready(1'b0),.done_error(error),.error_code(code));
initial begin repeat(3)@(negedge clk);rst_n=1;@(negedge clk);start_valid=1;@(negedge clk);start_valid=0;
repeat(5)@(negedge clk);if(!done||!error||code!==8'h80)$fatal(1,"static params");$display("PASS parameters");$finish;end endmodule'''
  with tempfile.TemporaryDirectory(prefix='png_encoder_params_') as tmp:
   d=Path(tmp);(d/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',d/'a.vvp',RTL,d/'tb.sv'],HERE,d/'compile.log');text=execute(['vvp',d/'a.vvp'],HERE,d/'sim.log');assert 'PASS parameters' in text
  rows.append(dict(width=w,height=h,error=128))
 assert hashes()==frozen
 (HERE/'parameter_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,cases=rows),indent=2)+'\n');print('PASS parameters',len(rows))
if __name__=='__main__':main()
