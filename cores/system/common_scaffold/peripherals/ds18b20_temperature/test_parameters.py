"""Reject illegal elaboration parameters without driving the sensor bus."""
from test_temperature import *
TB = r"""
`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start_valid=0;
wire low,done;wire[7:0]err;
ds18b20_temperature #(.CLK_HZ(@HZ@),.CONVERSION_TIMEOUT_US(@TIMEOUT@)) d(
.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(start_valid),.abort(1'b0),.ow_in(1'b1),
.cfg_match_rom(1'b0),.cfg_rom(64'b0),.done_ready(1'b0),.result_ready(1'b0),
.ow_drive_low(low),.done_valid(done),.error_code(err));
initial begin repeat(4)@(negedge clk);rst_n=1;repeat(4)@(negedge clk);start_valid=1;
repeat(4)@(negedge clk);if(!done||err!=1||low)$fatal(1,"illegal parameter did not reject");
$display("PASS invalid parameter");$finish;end
endmodule
"""
def main():
 frozen=hashes();rows=[]
 for hz,timeout in [(500000,1000),(27500000,1000),(251000000,1000),(27000000,0),(27000000,10000001)]:
  with tempfile.TemporaryDirectory(prefix='ds18_parameters_') as tmp:
   p=Path(tmp);(p/'tb.sv').write_text(TB.replace('@HZ@',str(hz)).replace('@TIMEOUT@',str(timeout)))
   execute(['iverilog','-g2012','-s','tb','-o',p/'sim',SOURCE,p/'tb.sv'],p,p/'compile.log')
   out=execute(['vvp',p/'sim'],p,p/'run.log');assert 'PASS invalid' in out
   rows.append(dict(clk_hz=hz,timeout_us=timeout,output=out))
 assert hashes()==frozen
 (HERE/'parameter_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,profiles=rows),indent=2)+'\n')
 print('PASS invalid parameter cases',len(rows))
if __name__=='__main__':main()
