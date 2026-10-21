from test_transactions import *
TB=r'''
`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,start_valid=0;wire done_valid,scl_drive_low,sda_drive_low;wire[3:0]error_code;
ds3231_rtc #(@PARAMS@)dut(.clk(clk),.rst_n(rst_n),.ce(1'b1),.start_valid(start_valid),.set_time(1'b0),.set_year(12'd2026),.set_month(4'd1),.set_day(6'd1),.set_weekday(3'd1),.set_hour(5'b0),.set_minute(6'b0),.set_second(6'b0),.result_ready(1'b0),.done_ready(1'b0),.scl_in(1'b1),.sda_in(1'b1),.done_valid(done_valid),.error_code(error_code),.scl_drive_low(scl_drive_low),.sda_drive_low(sda_drive_low));
initial begin repeat(4)@(negedge clk);rst_n=1;repeat(4)@(negedge clk);start_valid=1;repeat(4)@(negedge clk);
if(!done_valid||error_code!=8||scl_drive_low||sda_drive_low)$fatal(1,"invalid parameter did not reject");$display("PASS invalid RTC parameters");$finish;end
endmodule
'''
def main():
 frozen=hashes();dep=dependency();rows=[]
 for params in [dict(HALF_PERIOD_CYCLES=3),dict(STRETCH_TIMEOUT_CYCLES=3),dict(MAX_ROLLOVER_RETRIES=-1),dict(MAX_ROLLOVER_RETRIES=256)]:
  with tempfile.TemporaryDirectory(prefix='ds3231_parameters_') as tmp:
   p=Path(tmp);(p/'tb.sv').write_text(TB.replace('@PARAMS@',','.join(f'.{k}({v})' for k,v in params.items())),encoding='utf-8')
   execute(['iverilog','-g2012','-s','tb','-o',p/'sim',PHY,SOURCE,p/'tb.sv'],p,p/'compile.log');out=execute(['vvp',p/'sim'],p,p/'run.log');assert 'PASS invalid' in out;rows.append(dict(parameters=params,output=out))
 assert hashes()==frozen and dependency()==dep
 (HERE/'parameter_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,dependency_sha256=dep,profiles=rows),indent=2)+'\n',encoding='utf-8');print('PASS RTC invalid parameters',len(rows))
if __name__=='__main__':main()
