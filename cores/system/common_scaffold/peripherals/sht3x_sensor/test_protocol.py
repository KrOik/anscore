from run_tests import *
B=r"""`timescale 1ns/1ps
module tb;
reg clk=0;always #500 clk=~clk;reg rst_n=0,ce=1,abort=0,req_valid=0,out_ready=0;reg[6:0]req_address=7'h44;reg[1:0]req_repeatability=0;
wire req_ready,out_valid,busy,scl_drive_low,sda_drive_low;wire[3:0]out_error,out_phy_error;wire[1:0]out_crc_bad;wire[15:0]out_temperature_raw,out_humidity_raw,out_read_attempts;wire signed[18:0]out_temperature_mC;wire[16:0]out_humidity_mpercent;
reg dev_sda=0,dev_scl=0;wire scl_in=!(scl_drive_low||dev_scl),sda_in=!(sda_drive_low||dev_sda);
sht3x_sensor #(.CLOCK_HZ(1000000),.HALF_PERIOD_CYCLES(4),.STRETCH_TIMEOUT_CYCLES(20),.WAIT_LOW_US(1),.WAIT_MEDIUM_US(1),.WAIT_HIGH_US(1),.RETRY_GAP_US(1),.READ_ATTEMPTS(1))dut(.*);
task tick;begin @(negedge clk);#1;end endtask
initial begin
 if(@FAULT@==0)dev_scl=1;if(@FAULT@==1)dev_sda=1;
 repeat(4)tick;rst_n=1;req_valid=1;tick;req_valid=0;ce=0;
 if(@FAULT@>=2)begin
  wait(scl_drive_low); // START completed, before address bits.
  if(@FAULT@==2||@FAULT@==3)begin dev_scl=1;if(@FAULT@==3)begin repeat(10)tick;dev_scl=0;end end
  if(@FAULT@==4)dev_sda=1;
  if(@FAULT@==5)abort=1;
  if(@FAULT@==6)begin rst_n=0;tick;tick;if(out_valid||busy||scl_drive_low||sda_drive_low)$fatal(1,"active reset CE0");rst_n=1;repeat(3)tick;end
 end
 if(@FAULT@!=6)begin
  while(!out_valid)tick;
  if(out_error!=@ERROR@||out_phy_error!=@PHY@||scl_drive_low||sda_drive_low||out_read_attempts||out_temperature_mC||out_humidity_mpercent)$fatal(1,"physical result error%0d phy%0d",out_error,out_phy_error);
  repeat(7)tick;if(!out_valid)$fatal(1,"held physical error");
  dev_scl=0;dev_sda=0;abort=0;out_ready=1;tick;out_ready=0;if(out_valid)$fatal(1,"CE0 error ACK");
 end
 // All failure paths can accept a fresh request; absent slave gives new error2.
 ce=1;req_valid=1;tick;req_valid=0;while(!out_valid)tick;
 if(out_error!=2||out_phy_error||out_read_attempts)$fatal(1,"fresh recovery");
 rst_n=0;ce=0;tick;if(out_valid||busy||scl_drive_low||sda_drive_low)$fatal(1,"reset");
 $display("PASS SHT3X PHYSICAL @LABEL@");$finish;
end
initial begin #10000000;$fatal(1,"watchdog");end
endmodule"""
def main():
 rows=[]
 for i,label,error,phy in [(0,'busy_scl_timeout',8,5),(1,'busy_sda_timeout',8,5),(2,'clock_stretch_timeout',8,3),(3,'legal_clock_stretch_then_nack',2,0),(4,'arbitration_lost',8,4),(5,'abort_active_byte',7,0),(6,'reset_active_CE0',0,0)]:
  tb=B
  for k,v in dict(FAULT=i,LABEL=label,ERROR=error,PHY=phy).items():tb=tb.replace('@'+k+'@',str(v))
  with tempfile.TemporaryDirectory(prefix='sht3x_protocol_') as td:
   p=Path(td);(p/'tb.sv').write_text(tb,encoding='utf-8');execute(['iverilog','-g2012','-s','tb','-o',p/'sim',H/'sht3x_sensor.sv',PHY,p/'tb.sv'],p,H/f'protocol_{label}_compile.log');out=execute(['vvp',p/'sim'],p,H/f'protocol_{label}_simulation.log');assert 'PASS SHT3X PHYSICAL' in out
  rows.append(dict(label=label,status='PASS',error=error,physical_error=phy,output=out));print(out.splitlines()[0])
 save('protocol_evidence.json',rows,'Open-drain bus-busy/clock-stretch bounds, arbitration, legal stretch, abort in physical byte, CE0 synchronous reset; every failure accepts fresh descriptor with no stale status')
if __name__=='__main__':main()
