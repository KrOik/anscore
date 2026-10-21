"""Independent physical DS3231 shadow-register device; no DUT state inspection."""
from pathlib import Path
import hashlib,json,tempfile,sys
HERE=Path(__file__).resolve().parent;PACKAGE=HERE.parents[1]
PHY=PACKAGE/'peripherals/i2c_eeprom/i2c_eeprom_phy.sv';SOURCE=HERE/'ds3231_rtc.sv'
sys.path.insert(0,str(PACKAGE/'integration'))
from tooling import execute

def hashes():return {p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(HERE.iterdir()) if p.suffix in ('.sv','.py','.md','.f') or p.name in ('manifest.json','references.json','dependency_sha256.json')}
def dependency():return {PHY.relative_to(PACKAGE).as_posix():hashlib.sha256(PHY.read_bytes()).hexdigest()}
def bcd(x):return ((x//10)<<4)|(x%10)
TB=r'''
`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start_valid=0,set_time=@SET@,result_ready=0,done_ready=0;
reg[11:0]set_year=@YEAR@;reg[3:0]set_month=@MONTH@;reg[5:0]set_day=@DAY@;
reg[2:0]set_weekday=@WEEKDAY@;reg[4:0]set_hour=@HOUR@;reg[5:0]set_minute=@MINUTE@,set_second=@SECOND@;
wire start_ready,result_valid,busy,done_valid;wire[11:0]year;wire[3:0]month;wire[5:0]day,minute,second;wire[2:0]weekday;wire[4:0]hour;
wire[7:0]status_raw,retries;wire oscillator_stop,alarm1_flag,alarm2_flag,source_12h,source_century;wire[3:0]error_code;
wire scl_drive_low,sda_drive_low;reg dev_sda=0,dev_scl=0,fault_sda=0,fault_scl=0;
wire scl_in=!(scl_drive_low||dev_scl||fault_scl),sda_in=!(sda_drive_low||dev_sda||fault_sda);
ds3231_rtc #(.HALF_PERIOD_CYCLES(@HALF@),.STRETCH_TIMEOUT_CYCLES(@STRETCH_TIMEOUT@),.MAX_ROLLOVER_RETRIES(@LIMIT@))dut(.*);
reg[7:0]mem[0:31],shadow[0:6];integer cycle=0,j;
integer phase=4,bits=0,value=0,pointer=0,read_bit=0,burst_bytes=0,rollovers=0;
integer starts=0,stops=0,read_bytes=0,write_bytes=0;reg reading=0,ack=0,master_nack=0,force_off=0;
always @(negedge clk)begin cycle=cycle+1;ce=force_off?0:cycle%11>2;end
always @(negedge sda_in)if(rst_n&&scl_in)begin
 starts=starts+1;phase=0;bits=0;value=0;reading=0;dev_sda=0;
 for(integer x=0;x<7;x=x+1)shadow[x]=mem[x];
end
always @(posedge sda_in)if(rst_n&&scl_in)begin
 stops=stops+1;phase=4;reading=0;dev_sda=0;
 // Each seven-byte snapshot can advance the live calendar just after STOP.
 if(burst_bytes==7&&(@ROLLOVERS@<0||rollovers<@ROLLOVERS@))begin
  mem[0]=@ROLL_SECOND@;mem[1]=@ROLL_MINUTE@;mem[2]=@ROLL_HOUR@;mem[3]=@ROLL_WEEKDAY@;mem[4]=@ROLL_DAY@;mem[5]=@ROLL_MONTH@;mem[6]=@ROLL_YEAR@;
  if(@ROLLOVERS@<0)mem[0]=rollovers%2?8'h10:8'h11;
  rollovers=rollovers+1;
 end
 burst_bytes=0;
end
function[7:0]device_byte;input integer a;begin device_byte=a<7?shadow[a]:mem[a];end endfunction
always @(posedge scl_in)if(rst_n)begin
 if(reading)begin
  if(read_bit<8)read_bit=read_bit+1;
  else if(read_bit==8)begin master_nack=sda_in;read_bit=9;read_bytes=read_bytes+1;burst_bytes=burst_bytes+1;end
 end else if(phase!=4)begin
  if(bits<8)begin value=(value<<1)|sda_in;bits=bits+1;end else if(bits==8)bits=9;
 end
end
reg[7:0]out_byte;
always @(negedge scl_in)if(rst_n)begin
 if(reading)begin
  if(read_bit<8)begin out_byte=device_byte(pointer);dev_sda=~out_byte[7-read_bit];end
  else if(read_bit==8)dev_sda=0;
  else begin
   pointer=(pointer+1)%32;
   if(master_nack)begin reading=0;phase=4;dev_sda=0;end
   else begin read_bit=0;out_byte=device_byte(pointer);dev_sda=~out_byte[7];end
  end
 end else if(phase!=4)begin
  if(bits==8)begin
   ack=1;if(phase==0)ack=(value>>1)==7'h68&&!@NACK@;
   if(phase==2&&@DATA_NACK@)ack=0;
   dev_sda=ack;
  end else if(bits==9)begin
   dev_sda=0;
   if(!ack)phase=4;
   else if(phase==0)begin
    if(value&1)begin reading=1;read_bit=0;burst_bytes=0;out_byte=device_byte(pointer);dev_sda=~out_byte[7];end else phase=1;
   end else if(phase==1)begin pointer=value%32;phase=2;end
   else begin mem[pointer]=value;pointer=(pointer+1)%32;write_bytes=write_bytes+1;end
   bits=0;value=0;
  end
 end
end
always @(posedge scl_drive_low)if(rst_n&&@STRETCH@)begin dev_scl=1;fork begin @(negedge scl_drive_low);#90;dev_scl=0;end join_none end
reg held=0;reg[67:0]saved;
always @(posedge clk)if(rst_n)begin
 if(held&&(!result_valid||{year,month,day,weekday,hour,minute,second,status_raw,source_12h,source_century,retries}!==saved))$fatal(1,"held RTC result changed");
 held=result_valid&&!(ce&&result_ready);saved={year,month,day,weekday,hour,minute,second,status_raw,source_12h,source_century,retries};
end else held=0;
task automatic request;begin
 @(negedge clk);#1;start_valid=1;
 @(posedge clk);while(!(ce&&start_ready))@(posedge clk);
 @(negedge clk);#1;start_valid=0;set_time=~set_time;set_year=0;set_month=0;set_day=0;set_hour=0;set_minute=0;set_second=0;set_weekday=0;
end endtask
task automatic completion;input integer code;begin
 wait(done_valid);@(negedge clk);#1;if(error_code!=code||busy||result_valid||scl_drive_low||sda_drive_low)$fatal(1,"RTC error%0d exp%0d",error_code,code);
 force_off=1;ce=0;done_ready=1;repeat(6)@(negedge clk);#1;if(!done_valid)$fatal(1,"DONE consumed CE0");
 force_off=0;@(posedge clk);while(!ce)@(posedge clk);
 @(negedge clk);#1;done_ready=0;if(!start_ready)$fatal(1,"restart readiness");
end endtask
initial begin
 for(j=0;j<32;j=j+1)mem[j]=0;
 @REGS@
 mem[15]=8'h@STATUS@;
 repeat(5)@(negedge clk);#1;rst_n=1;repeat(5)@(negedge clk);
 @HOST@
 $display("PASS DS3231 @LABEL@ starts=%0d stops=%0d rb=%0d wb=%0d retries=%0d",starts,stops,read_bytes,write_bytes,retries);$finish;
end
initial begin #10000000;$fatal(1,"RTC watchdog");end
endmodule
'''
READ=r'''
 request;wait(result_valid);@(negedge clk);#1;
 if(year!=@YEAR@||month!=@MONTH@||day!=@DAY@||weekday!=@WEEKDAY@||hour!=@HOUR@||minute!=@MINUTE@||second!=@SECOND@||source_12h!=@TWELVE@||source_century!=(@YEAR@>=2100)||status_raw!=8'h@STATUS@||oscillator_stop!=@OSF@||alarm1_flag!=@A1F@||alarm2_flag!=@A2F@||retries!=@EXPECTED_RETRIES@)$fatal(1,"RTC decoded result y%0d m%0d d%0d h%0d min%0d sec%0d",year,month,day,hour,minute,second);
 force_off=1;ce=0;result_ready=1;repeat(80)@(negedge clk);#1;if(!result_valid||done_valid)$fatal(1,"CE0 result consumed");
 force_off=0;@(posedge clk);while(!ce)@(posedge clk);
 @(negedge clk);#1;result_ready=0;completion(0);
 if(write_bytes!=0||starts!=6*(@EXPECTED_RETRIES@+1)||stops!=3*(@EXPECTED_RETRIES@+1)||read_bytes!=9*(@EXPECTED_RETRIES@+1))$fatal(1,"snapshot/status/verify transaction framing");
'''
SET=r'''
 request;completion(0);
 @VERIFY_WRITES@
 if(starts!=1||stops!=1||write_bytes!=7||mem[15]!=8'h@STATUS@)$fatal(1,"SET touched unexpected registers");
'''
def run(label,values=(2026,10,19,1,23,59,58),raw=None,twelve=False,pm=False,status=0x83,set_op=False,host=None,nack=False,data_nack=False,stretch=False,rollovers=0,roll_values=None,retry_limit=2,expected_retries=0,half=6,stretch_timeout=80):
 year,month,day,weekday,hour,minute,second=values
 regs=[bcd(second),bcd(minute),bcd(hour),weekday,bcd(day),bcd(month)|(0x80 if year>=2100 else 0),bcd(year%100)]
 if twelve:regs[2]=0x40|(0x20 if hour>=12 else 0)|bcd(hour%12 or 12)
 if raw is not None:regs=list(raw)
 rv=values if roll_values is None else roll_values;ry,rm,rd,rw,rh,rmi,rs=rv
 rregs=[bcd(rs),bcd(rmi),bcd(rh),rw,bcd(rd),bcd(rm)|(128 if ry>=2100 else 0),bcd(ry%100)]
 expect=rv if expected_retries else values
 ey,em,ed,ew,eh,emi,es=expect
 checks='\n'.join(f'if(mem[{i}]!==8\'h{x:02x})$fatal(1,"SET BCD byte{i}");' for i,x in enumerate(regs))
 args=dict(STRETCH_TIMEOUT=stretch_timeout,LABEL=label,REGS='\n'.join(f'mem[{i}]=8\'h{x:02x};' for i,x in enumerate(regs)),SET=int(set_op),YEAR=ey,MONTH=em,DAY=ed,WEEKDAY=ew,HOUR=eh,MINUTE=emi,SECOND=es,STATUS=f'{status:02x}',OSF=(status>>7)&1,A1F=status&1,A2F=(status>>1)&1,TWELVE=int(twelve and not expected_retries),NACK=int(nack),DATA_NACK=int(data_nack),STRETCH=int(stretch),ROLLOVERS=rollovers,ROLL_SECOND=rregs[0],ROLL_MINUTE=rregs[1],ROLL_HOUR=rregs[2],ROLL_WEEKDAY=rregs[3],ROLL_DAY=rregs[4],ROLL_MONTH=rregs[5],ROLL_YEAR=rregs[6],LIMIT=retry_limit,EXPECTED_RETRIES=expected_retries,HALF=half,HOST=(SET if set_op else READ) if host is None else host,VERIFY_WRITES=checks)
 text=TB
 for _ in range(3):
  for k,v in args.items():text=text.replace('@'+k+'@',str(v))
 with tempfile.TemporaryDirectory(prefix='ds3231_') as tmp:
  p=Path(tmp);(p/'tb.sv').write_text(text,encoding='utf-8')
  execute(['iverilog','-g2012','-s','tb','-o',p/'sim',PHY,SOURCE,p/'tb.sv'],p,p/'compile.log')
  out=execute(['vvp',p/'sim'],p,p/'run.log');assert 'PASS DS3231' in out
  (HERE/('simulation_'+label+'.log')).write_text(out,encoding='utf-8');print(out.strip(),flush=True)
 return dict(label=label,values=expect,registers=regs,set_time=set_op,output=out)
def main():
 frozen=hashes();dep=dependency();rows=[]
 for vals,label in [((2026,10,19,1,23,59,58),'24h'),((2000,2,29,2,0,0,0),'leap2000'),((2100,3,1,1,12,0,0),'century2100'),((2199,12,31,7,23,59,59),'last2199')]:rows.append(run(label,vals))
 for h in [0,1,11,12,13,23]:rows.append(run('12h_'+str(h),values=(2026,1,1,4,h,2,3),twelve=True))
 rows.append(run('set_leap',values=(2024,2,29,4,16,45,30),set_op=True))
 rows.append(run('set_century',values=(2100,3,1,1,0,0,0),set_op=True))
 rows.append(run('stretch',stretch=True))
 rows.append(run('rollover_once',values=(2099,12,31,7,23,59,59),rollovers=1,roll_values=(2100,1,1,1,0,0,0),expected_retries=1))
 assert hashes()==frozen and dependency()==dep
 (HERE/'transaction_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,dependency_sha256=dep,profiles=rows),indent=2)+'\n',encoding='utf-8')
if __name__=='__main__':main()
