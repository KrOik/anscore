"""Reject invalid static specializations explicitly rather than hanging."""
import tempfile,json
from pathlib import Path
from run_tests import HERE,RTL,hashes,execute
def main():
 frozen=hashes();rows=[]
 for w,h,bits in [(0,4,8),(4,0,8),(257,4,8),(4,257,8),(4,4,9)]:
  tb=f'''module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,start_valid=0;wire ready,done,error;wire[7:0]code;
raw_black_level #(.WIDTH({w}),.HEIGHT({h}),.BITS({bits}))dut(
.clk(clk),.rst_n(rst_n),.ce(1'b1),.start_valid(start_valid),.start_ready(ready),
.cfg_auto(1'b0),.cfg_pattern(2'b00),.cfg_black_levels({4*bits}'d0),.cfg_target_pedestal({bits}'d0),
.cfg_roi_x(16'd0),.cfg_roi_y(16'd0),.cfg_roi_width(16'd0),.cfg_roi_height(16'd0),.abort(1'b0),
.s_data({bits}'d0),.s_valid(1'b0),.s_sof(1'b0),.s_eol(1'b0),.s_last(1'b0),.m_ready(1'b1),
.done_valid(done),.done_ready(1'b0),.done_error(error),.error_code(code));
initial begin repeat(3)@(negedge clk);rst_n=1;@(negedge clk);start_valid=1;@(negedge clk);start_valid=0;
repeat(5)@(negedge clk);if(!done||!error||code!==8'h80)$fatal(1,"bad static params");$display("PASS parameters");$finish;end endmodule'''
  with tempfile.TemporaryDirectory(prefix='raw_blc_params_') as tmp:
   d=Path(tmp);(d/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',d/'a.vvp',RTL,d/'tb.sv'],HERE,d/'compile.log');text=execute(['vvp',d/'a.vvp'],HERE,d/'sim.log');assert 'PASS parameters' in text
  rows.append(dict(width=w,height=h,bits=bits,error=128))
 assert hashes()==frozen
 (HERE/'parameter_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,cases=rows),indent=2)+'\n');print('PASS static parameters',len(rows))
if __name__=='__main__':main()
