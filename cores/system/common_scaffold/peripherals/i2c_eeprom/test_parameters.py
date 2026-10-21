"""Invalid compile-time parameter and physical-idle rejection tests."""
from test_transactions import *
TB=r'''
`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,start_valid=0;
wire done_valid,scl_drive_low,sda_drive_low;wire[3:0]error_code;
i2c_eeprom #(@PARAMS@)dut(.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(start_valid),.write(1'b0),.device_address(7'h50),.word_address(16'b0),.length(16'd1),.tx_valid(1'b0),.tx_data(8'b0),.rx_ready(1'b0),.done_ready(1'b0),.scl_in(1'b1),.sda_in(1'b1),.done_valid(done_valid),.error_code(error_code),.scl_drive_low(scl_drive_low),.sda_drive_low(sda_drive_low));
initial begin repeat(4)@(negedge clk);rst_n=1;repeat(4)@(negedge clk);start_valid=1;repeat(4)@(negedge clk);
if(!done_valid||error_code!=8||scl_drive_low||sda_drive_low)$fatal(1,"invalid parameter must reject before START");$display("PASS EEPROM invalid parameters");$finish;end
endmodule
'''
def main():
 frozen=hashes();rows=[]
 for params in [dict(ADDR_BYTES=0),dict(ADDR_BYTES=3),dict(ADDR_BYTES=1,CAPACITY_BYTES=512),dict(CAPACITY_BYTES=0),dict(CAPACITY_BYTES=65537),dict(PAGE_BYTES=0),dict(PAGE_BYTES=3),dict(PAGE_BYTES=512),dict(CAPACITY_BYTES=8,PAGE_BYTES=16),dict(HALF_PERIOD_CYCLES=3),dict(STRETCH_TIMEOUT_CYCLES=3),dict(POLL_LIMIT=0),dict(POLL_LIMIT=65536),dict(POLL_GAP_CYCLES=0),dict(HOST_TIMEOUT_CYCLES=0)]:
  with tempfile.TemporaryDirectory(prefix='i2c_eeprom_parameters_') as tmp:
   p=Path(tmp);(p/'tb.sv').write_text(TB.replace('@PARAMS@',','.join(f'.{k}({v})' for k,v in params.items())),encoding='utf-8')
   execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*SOURCES,p/'tb.sv'],p,p/'compile.log')
   out=execute(['vvp',p/'sim'],p,p/'run.log');assert 'PASS EEPROM' in out;rows.append(dict(parameters=params,output=out))
 assert hashes()==frozen
 (HERE/'parameter_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,profiles=rows),indent=2)+'\n',encoding='utf-8');print('PASS invalid parameter profiles',len(rows))
if __name__=='__main__':main()
