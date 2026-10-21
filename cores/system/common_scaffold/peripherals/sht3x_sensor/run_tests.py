from pathlib import Path
import sys,tempfile,json,hashlib,random
H=Path(__file__).resolve().parent;PACKAGE=H.parents[1];PHY=PACKAGE/'peripherals/i2c_eeprom/i2c_eeprom_phy.sv';sys.path.insert(0,str(PACKAGE/'integration'))
from tooling import execute
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def sources():return {'sht3x_sensor.sv':sha(H/'sht3x_sensor.sv')}
def dependencies():return {'peripherals/i2c_eeprom/i2c_eeprom_phy.sv':sha(PHY)}
def crc(v):
 c=255
 for b in v.to_bytes(2,'big'):
  c^=b
  for _ in range(8):c=((c<<1)^0x31)&255 if c&128 else (c<<1)&255
 return c
assert crc(0xbeef)==0x92
TB=r"""`timescale 1ns/1ps
module tb;
reg clk=0;always #500 clk=~clk;reg rst_n=0,ce=0,abort=0,req_valid=0,out_ready=0;reg[6:0]req_address=@ADDR@;reg[1:0]req_repeatability=@REP@;
wire req_ready,out_valid,busy,scl_drive_low,sda_drive_low;wire[3:0]out_error,out_phy_error;wire[1:0]out_crc_bad;wire[15:0]out_temperature_raw,out_humidity_raw,out_read_attempts;wire signed[18:0]out_temperature_mC;wire[16:0]out_humidity_mpercent;
reg dev_sda=0,dev_scl=0;wire scl_in=!(scl_drive_low||dev_scl),sda_in=!(sda_drive_low||dev_sda);
sht3x_sensor #(.CLOCK_HZ(1000000),.HALF_PERIOD_CYCLES(4),.STRETCH_TIMEOUT_CYCLES(20),.WAIT_LOW_US(@WL@),.WAIT_MEDIUM_US(@WM@),.WAIT_HIGH_US(@WH@),.RETRY_GAP_US(9),.READ_ATTEMPTS(@LIMIT@))dut(.*);
integer starts=0,stops=0,received=0,transmitted=0,polls=0;reg model_done=0;time wstop,priorstop;
task tick;begin @(negedge clk);#1;end endtask
task await_start;begin : search forever begin @(negedge sda_in);if(scl_in)begin starts=starts+1;disable search;end end end endtask
task await_stop;begin : search forever begin @(posedge sda_in);if(scl_in)begin stops=stops+1;priorstop=$time;disable search;end end end endtask
task receive;input[7:0]expected;input ack;reg[7:0]v;integer j;begin
 v=0;for(j=0;j<8;j=j+1)begin @(posedge scl_in);v={v[6:0],sda_in};@(negedge scl_in);end
 if(v!==expected)$fatal(1,"pin received%0d got%h expected%h",received,v,expected);received=received+1;
 dev_sda=ack;@(posedge scl_in);if(sda_in!==!ack)$fatal(1,"slave ACK");@(negedge scl_in);dev_sda=0;
end endtask
task transmit;input[7:0]v;input last;integer j;begin
 for(j=7;j>=0;j=j-1)begin dev_sda=!v[j];@(posedge scl_in);@(negedge scl_in);end
 dev_sda=0;@(posedge scl_in);if(sda_in!==last)$fatal(1,"master read ACK/NACK index%0d",transmitted);transmitted=transmitted+1;@(negedge scl_in);
end endtask
integer q;
initial begin
 wait(rst_n);await_start;receive((@ADDR@<<1),@NACK@!=1);
 if(@NACK@==1)begin await_stop;model_done=1;end
 else begin
  receive(8'h24,@NACK@!=2);
  if(@NACK@==2)begin await_stop;model_done=1;end
  else begin
   receive(@CMD@,@NACK@!=3);await_stop;wstop=$time;
   if(@NACK@==3)model_done=1;
   else if(@ABORT@)begin abort=1;await_stop;abort=0;model_done=1;end
   else begin
    for(q=0;q<@TRIES@;q=q+1)begin
     await_start;
     if(q==0&&$time-wstop<@WAIT@*1000)$fatal(1,"measurement wait too short");
     if(q>0&&$time-priorstop<9000)$fatal(1,"retry gap too short");
     receive((@ADDR@<<1)|1,q>=@BUSY@);polls=polls+1;
     if(q<@BUSY@)await_stop;
     else begin transmit(@TH@,0);transmit(@TL@,0);transmit(@TC@,0);transmit(@HH@,0);transmit(@HL@,0);transmit(@HC@,1);await_stop;end
    end
    model_done=1;
   end
  end
 end
end
reg[95:0]held;integer oldstarts;
initial begin
 repeat(4)tick;rst_n=1;req_valid=1;repeat(12)tick;
 if(req_ready||busy||scl_drive_low||sda_drive_low)$fatal(1,"CE0 request");ce=1;tick;req_valid=0;
 // Snapshot host fields; then keep CE0 for the complete physical transaction.
 req_address=7'h12;req_repeatability=3;ce=0;
 while(!out_valid)tick;
 if(out_error!=@ERROR@||out_phy_error||out_read_attempts!=@ATTEMPTS@||out_crc_bad!=@CRCFLAGS@)$fatal(1,"status error%0d phy%0d attempts%0d crc%0d",out_error,out_phy_error,out_read_attempts,out_crc_bad);
 if(@HASDATA@&&(out_temperature_raw!=@T@||out_humidity_raw!=@H@))$fatal(1,"raw result");
 if(out_temperature_mC!=@TEMP@||out_humidity_mpercent!=@HUM@)$fatal(1,"engineering got%0d %0d expected@TEMP@ @HUM@",out_temperature_mC,out_humidity_mpercent);
 held={out_error,out_crc_bad,out_temperature_raw,out_humidity_raw,out_temperature_mC,out_humidity_mpercent,out_read_attempts};
 repeat(17)tick;if(!out_valid||req_ready||{out_error,out_crc_bad,out_temperature_raw,out_humidity_raw,out_temperature_mC,out_humidity_mpercent,out_read_attempts}!==held)$fatal(1,"output stall");
 while(!model_done)tick;
 if(starts!=@STARTS@||stops!=@STOPS@||transmitted!=@READBYTES@)$fatal(1,"physical transcript starts%0d stops%0d data%0d",starts,stops,transmitted);
 out_ready=1;tick;out_ready=0;if(out_valid||busy)$fatal(1,"CE0 response pop");
 rst_n=0;tick;if(out_valid||busy||scl_drive_low||sda_drive_low)$fatal(1,"reset CE0");
 $display("PASS SHT3X @LABEL@ error=%0d attempts=%0d starts=%0d stops=%0d",@ERROR@,@ATTEMPTS@,starts,stops);$finish;
end
initial begin #100000000;$fatal(1,"watchdog");end
endmodule"""
def run(label,t=0xbeef,h=0x1234,rep=2,address=0x44,busy=0,limit=4,nack=0,badcrc=0,abort=0,actual_wait=False):
 wl,wm,wh=(5000,7000,16000) if actual_wait else (5,7,16)
 tries=min(busy+1,limit);hasdata=not nack and not abort and busy<limit
 error=2 if nack==1 else 3 if nack else 7 if abort else 4 if busy>=limit else 5 if badcrc&1 else 6 if badcrc&2 else 0
 attempts=0 if nack or abort else tries
 expectedt=-45000+(175000*t+32767)//65535 if error==0 else 0;expectedh=(100000*h+32767)//65535 if error==0 else 0
 mapping=dict(ADDR=address,REP=rep,CMD=[0x16,0x0b,0][rep],WL=wl,WM=wm,WH=wh,WAIT=[wl,wm,wh][rep],LIMIT=limit,NACK=nack,ABORT=abort,TRIES=tries,BUSY=busy,TH=t>>8,TL=t&255,TC=crc(t)^(1 if badcrc&1 else 0),HH=h>>8,HL=h&255,HC=crc(h)^(1 if badcrc&2 else 0),ERROR=error,ATTEMPTS=attempts,CRCFLAGS=badcrc if hasdata else 0,HASDATA=int(hasdata),T=t,H=h,TEMP=expectedt,HUM=expectedh,STARTS=1+attempts,STOPS=1+attempts+(1 if abort else 0),READBYTES=6 if hasdata else 0,LABEL=label)
 tb=TB
 for k,v in mapping.items():tb=tb.replace('@'+k+'@',str(v))
 with tempfile.TemporaryDirectory(prefix='sht3x_sensor_') as td:
  p=Path(td);(p/'tb.sv').write_text(tb,encoding='utf-8');execute(['iverilog','-g2012','-s','tb','-o',p/'sim',H/'sht3x_sensor.sv',PHY,p/'tb.sv'],p,H/f'compile_{label}.log');out=execute(['vvp',p/'sim'],p,H/f'simulation_{label}.log');assert 'PASS SHT3X' in out
 print(out.splitlines()[0]);return dict(label=label,status='PASS',parameters=dict(temperature_raw=t,humidity_raw=h,repeatability=rep,address=address,busy_nacks=busy,error=error),output=out,simulation_log=f'simulation_{label}.log',simulation_sha256=sha(H/f'simulation_{label}.log'))
def save(name,rows,scope):
 (H/name).write_text(json.dumps(dict(status='PASS',sources=sources(),dependencies=dependencies(),profiles=rows,scope=scope),indent=2)+'\n',encoding='utf-8')
def main():
 rows=[]
 for rep in range(3):
  for addr in (0x44,0x45):rows.append(run(f'rep{rep}_addr{addr}',t=[0,0xffff,0xbeef][rep],h=[0xffff,0,0x1234][rep],rep=rep,address=addr,busy=rep))
 r=random.Random(718)
 for i in range(12):rows.append(run(f'random{i}',t=r.randrange(65536),h=r.randrange(65536),rep=i%3,address=0x44+i%2,busy=i%4))
 rows.append(run('default_high_wait',actual_wait=True))
 save('transaction_evidence.json',rows,'Independent scripted pin device: exact command/address bytes, busyNACK/read retry, read six bytes and ACK/NACK, raw and Python integer engineering values, CE0 and backpressure, reset')
if __name__=='__main__':main()
