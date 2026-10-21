from run_tests import *
B=r"""module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=0,abort=0,req_valid=1,out_ready=0;reg[6:0]req_address=@ADDR@;reg[1:0]req_repeatability=@REP@;wire req_ready,out_valid,busy,scl_drive_low,sda_drive_low;wire[3:0]out_error,out_phy_error;wire[1:0]out_crc_bad;wire[15:0]out_temperature_raw,out_humidity_raw,out_read_attempts;wire signed[18:0]out_temperature_mC;wire[16:0]out_humidity_mpercent;wire scl_in=1,sda_in=1;
sht3x_sensor #(@PARAMS@)dut(.*);
initial begin repeat(3)@(negedge clk);rst_n=1;repeat(4)@(negedge clk);#1;if(req_ready||out_valid||scl_drive_low||sda_drive_low)$fatal(1,"CE0 request");ce=1;@(negedge clk);#1;req_valid=0;ce=0;
if(!out_valid||out_error!=1||out_phy_error||out_read_attempts||scl_drive_low||sda_drive_low)$fatal(1,"invalid report");repeat(8)@(negedge clk);#1;if(!out_valid)$fatal(1,"held invalid");out_ready=1;@(negedge clk);#1;if(out_valid)$fatal(1,"CE0 output ACK");rst_n=0;@(negedge clk);#1;if(busy||out_valid||scl_drive_low||sda_drive_low)$fatal(1,"reset");$display("PASS SHT3X INVALID PARAMETER");$finish;end endmodule"""
def main():
 rows=[]
 invalid=[('CLOCK_HZ',0),('CLOCK_HZ',999999),('CLOCK_HZ',100000001),('HALF_PERIOD_CYCLES',3),('STRETCH_TIMEOUT_CYCLES',3),('WAIT_LOW_US',0),('WAIT_MEDIUM_US',0),('WAIT_HIGH_US',1000001),('RETRY_GAP_US',0),('RETRY_GAP_US',1000001),('READ_ATTEMPTS',0),('READ_ATTEMPTS',65536)]
 cases=[(dict([v]),0x44,0) for v in invalid]+[({},0x43,0),({},0x46,0),({},0x44,3)]
 for i,(params,addr,rep) in enumerate(cases):
  spec=params or {'CLOCK_HZ':1000000};tb=B.replace('@PARAMS@',','.join(f'.{k}({v})' for k,v in spec.items())).replace('@ADDR@',str(addr)).replace('@REP@',str(rep))
  with tempfile.TemporaryDirectory(prefix='sht3x_parameters_') as td:
   p=Path(td);(p/'tb.sv').write_text(tb,encoding='utf-8');execute(['iverilog','-g2012','-s','tb','-o',p/'sim',H/'sht3x_sensor.sv',PHY,p/'tb.sv'],p,H/f'param_{i}_compile.log');out=execute(['vvp',p/'sim'],p,H/f'param_{i}_simulation.log');assert 'PASS SHT3X INVALID' in out
  rows.append(dict(parameters=params,address=addr,repeatability=rep,status='PASS',output=out))
 save('parameter_evidence.json',rows,'Twelve illegal static settings and three invalid commands all report error1 without any I2C transaction; CE0 response/reset')
 print('PASS15 SHT3X INVALID')
if __name__=='__main__':main()
