"""Pin-only DS18B20 model: parses master bytes and independently drives replies."""
from pathlib import Path
import hashlib,json,tempfile,sys,re
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import execute
SOURCE=HERE/'ds18b20_temperature.sv'
def hashes():
 files=sorted(p for p in HERE.iterdir() if p.suffix in ['.sv','.py','.md','.f'] or p.name in ['manifest.json','references.json'])
 return {p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
def crc8(values):
 c=0
 for b in values:
  for bit in range(8):
   mix=(c^(b>>bit))&1;c>>=1
   if mix:c^=0x8c
 return c
ROM_BYTES=[0x28,0x91,0x37,0x05,0x16,0x09,0x24]
ROM=sum(b<<(8*i) for i,b in enumerate(ROM_BYTES+[crc8(ROM_BYTES)]))
TB=r'''
`timescale 1us/1ps
module tb;
localparam HZ=@HZ@;
reg clk=0;always #(500000.0/HZ)clk=~clk;
reg rst_n=0,ce=1,start_valid=0,abort=0,done_ready=0,result_ready=0;
reg cfg_match_rom=@MATCH@;reg[63:0]cfg_rom=64'h@ROM@;
wire start_ready,ow_drive_low,busy,done_valid,result_valid;wire[7:0]error_code;
wire signed[15:0]temperature_q4;wire[1:0]resolution;wire[71:0]scratchpad;
reg device_low=0,stuck=@STUCK@;
wire ow_in=!(ow_drive_low||device_low||stuck);
ds18b20_temperature #(.CLK_HZ(HZ),.CONVERSION_TIMEOUT_US(@TIMEOUT@)) d(.*);
reg[71:0]device_scratch=72'h@SCRATCH@;reg[63:0]expected_rom=64'h@ROM@;
integer phase=0,resets=0,byte_bits=0,byte_value=0,rom_index=0,read_index=0,polls=0,commands=0;
integer writes=0,reads=0,cycle=0;reg selected=0,reply=1,slot_read=0,force_off=0;
realtime low_start=0,low_width=0,slot_start=0,conversion_start=0;
always @(negedge clk)begin cycle=cycle+1;ce=force_off?0:cycle%11>2;end
// Device sees only physical drive transitions. No internal DUT signals/states.
always @(posedge ow_drive_low)begin
 low_start=$realtime;
 if(phase==3&&polls==0)conversion_start=$realtime;
 slot_read=phase==3||phase==4;
 if(slot_read)begin
  reply=phase==3?(@READY_US@>=0?($realtime-conversion_start>=@READY_US@):(@BUSY@?1'b0:polls>=@READY_AFTER@)):device_scratch[read_index];
  if(!reply)fork
   begin #(@REPLY_START@);device_low=1;
    if(phase==3&&@READY_US@>=0&&@READY_US@-($realtime-conversion_start)<@REPLY_END@-@REPLY_START@)begin
     if(@READY_US@>($realtime-conversion_start))#(@READY_US@-($realtime-conversion_start));
    end else #(@REPLY_END@-@REPLY_START@);
    device_low=0;end
  join_none
 end
end
always @(negedge ow_drive_low)if(rst_n)begin
 low_width=$realtime-low_start;
 if(low_width>=400)begin
  if(low_width<479.99||low_width>481.01)$fatal(1,"physical reset low %f us",low_width);
  resets=resets+1;phase=0;byte_bits=0;byte_value=0;rom_index=0;selected=0;
  if(@SECOND_STUCK@&&resets==2)device_low=1;
  else if(@NOPRESENCE@==0||(@NOPRESENCE@==2&&resets==1))fork begin #(@PRESENCE_DELAY@);device_low=1;#(@PRESENCE_WIDTH@);device_low=0;end join_none
 end else if(slot_read)begin
  if(low_width<2.99||low_width>3.01)$fatal(1,"read-init low width %f",low_width);
  reads=reads+1;
  if(phase==3)polls=polls+1;else read_index=read_index+1;
 end else begin
  if((low_width<5.99||low_width>6.01)&&(low_width<59.99||low_width>60.01))$fatal(1,"write low %f CE stretched or truncated",low_width);
  byte_value=byte_value|((low_width<15?1:0)<<byte_bits);byte_bits=byte_bits+1;writes=writes+1;
  if(byte_bits==8)begin
   commands=commands+1;
   if(phase==0)begin
    if(byte_value!=(@MATCH@?'h55:'hcc))$fatal(1,"ROM command %h",byte_value);
    phase=@MATCH@?1:2;if(!@MATCH@)selected=1;
   end else if(phase==1)begin
    if(byte_value!==((expected_rom>>(8*rom_index))&255))$fatal(1,"Match ROM byte%0d",rom_index);
    rom_index=rom_index+1;if(rom_index==8)begin phase=2;selected=1;end
   end else if(phase==2)begin
    if(!selected||byte_value!=(resets==1?'h44:'hbe))$fatal(1,"function command %h reset%0d",byte_value,resets);
    if(resets==1)begin phase=3;polls=0;end else begin phase=4;read_index=0;end
   end else $fatal(1,"unexpected command state");
   byte_bits=0;byte_value=0;
  end
 end
end
reg held=0;reg[89:0]held_value;
always @(posedge clk)if(rst_n)begin
 if(held&&(!result_valid||{temperature_q4,resolution,scratchpad}!==held_value))$fatal(1,"result withdrawn/changed while held");
 held=result_valid&&!(ce&&result_ready);held_value={temperature_q4,resolution,scratchpad};
end else held=0;
task request;
begin
 @(negedge clk);#0.01;start_valid=1;
 begin:a forever begin @(posedge clk);if(ce&&start_ready)begin #0.01;disable a;end end end
 @(negedge clk);#0.01;start_valid=0;cfg_match_rom=~cfg_match_rom;cfg_rom=0;
end endtask
task ask_abort;
begin @(negedge clk);#0.01;abort=1;
 begin:a forever begin @(posedge clk);if(ce)begin #0.01;disable a;end end end
 @(negedge clk);#0.01;abort=0;
end endtask
initial begin
 repeat(5)@(negedge clk);#0.01;rst_n=1;repeat(5)@(negedge clk);request;
 @HOST_ACTION@
 wait(done_valid);@(negedge clk);#0.01;
 if(error_code!=@ERROR@||busy||ow_drive_low||result_valid)$fatal(1,"completion error%0d expected%0d",error_code,@ERROR@);
 force_off=1;ce=0;done_ready=1;repeat(6)@(negedge clk);#0.01;if(!done_valid)$fatal(1,"CEoff DONE ack");
 force_off=0;
 begin:a forever begin @(posedge clk);if(ce)begin #0.01;disable a;end end end
 @(negedge clk);#0.01;if(!start_ready)$fatal(1,"restart not ready");
 $display("PASS DS18 label=@LABEL@ resets=%0d writebits=%0d readslots=%0d polls=%0d",resets,writes,reads,polls);$finish;
end
initial begin #2000000;$fatal(1,"watchdog");end
endmodule
'''
SUCCESS=r'''
 wait(result_valid);@(negedge clk);#0.01;
 if(temperature_q4!==16'sh@TEMP@||resolution!=@RES@||scratchpad!==72'h@SCRATCH@)$fatal(1,"temperature/resolution/scratchpad mismatch temp%h res%0d",temperature_q4,resolution);
 if(resets!=2||read_index!=72)$fatal(1,"not complete 9-byte transaction");
 force_off=1;ce=0;result_ready=1;repeat(12)@(negedge clk);#0.01;if(!result_valid||done_valid)$fatal(1,"CEoff result consumed");
 force_off=0;result_ready=0;
 @ABORT_HELD@
 result_ready=1;
'''
def run(label,raw=0x0191,res=3,match=False,hz=1000000,error=0,busy=False,nopresence=False,stuck=False,corrupt=False,abort_at=None,reply_start=2,reply_end=15,timeout=1000,ready_after=2,presence_delay=30,presence_width=120,ready_us=-1,second_stuck=False):
 values=[raw&255,(raw>>8)&255,0x4b,0x46,0x1f|(res<<5),0xff,0x0c,0x10];values.append(crc8(values))
 if corrupt:values[-1]^=1
 scratch=sum(b<<(8*i) for i,b in enumerate(values));expected=(raw&0xffff)&(~((1<<(3-res))-1)&0xffff)
 action=SUCCESS if error==0 or abort_at=='held' else ''
 abortheld='ask_abort;repeat(12)@(negedge clk);#0.01;if(!result_valid||done_valid)$fatal(1,"abort withdrew exposed result");' if abort_at=='held' else ''
 if abort_at=='reset':action='wait(ow_drive_low);repeat(20)@(negedge clk);ask_abort;'
 if abort_at=='write':action='wait(commands==1);wait(ow_drive_low);ask_abort;'
 if abort_at=='read':action='wait(phase==4);wait(ow_drive_low);ask_abort;'
 action=action.replace('@ABORT_HELD@',abortheld)
 params=dict(SECOND_STUCK=int(second_stuck),READY_US=ready_us,PRESENCE_DELAY=presence_delay,PRESENCE_WIDTH=presence_width,HZ=hz,MATCH=int(match),ROM=f'{ROM:016x}',SCRATCH=f'{scratch:018x}',TIMEOUT=timeout,READY_AFTER=ready_after,STUCK=int(stuck),BUSY=int(busy),NOPRESENCE=int(nopresence),REPLY_START=reply_start,REPLY_END=reply_end,HOST_ACTION=action,ERROR=error,LABEL=label,TEMP=f'{expected:04x}',RES=res)
 tb=TB
 for k,v in params.items():tb=tb.replace('@'+k+'@',str(v))
 # Action text itself contains placeholders, so apply substitutions once again.
 for k,v in params.items():tb=tb.replace('@'+k+'@',str(v))
 with tempfile.TemporaryDirectory(prefix='ds18_temperature_') as tmp:
  p=Path(tmp);(p/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',p/'sim',SOURCE,p/'tb.sv'],p,p/'compile.log')
  out=execute(['vvp',p/'sim'],p,p/'run.log');(HERE/f'simulation_{label}.log').write_text(out)
 assert 'PASS DS18' in out;print(out.strip(),flush=True)
 return dict(label=label,raw=f'{raw&65535:04x}',resolution=res,match=match,clk_hz=hz,error=error,scratchpad=f'{scratch:018x}',expected_temperature_q4=expected if expected<32768 else expected-65536,output=out)
def main():
 frozen=hashes();rows=[]
 for raw,label in [(0x0191,'positive25_0625'),(0xff5e,'negative10_125'),(0x0550,'powerup85'),(0xfc90,'minus55'),(0x07d0,'plus125')]:rows.append(run(label,raw,match=raw&1!=0))
 for r in range(4):rows.append(run('resolution'+str(r),0xff5f,res=r,match=True))
 rows.append(run('crc_error',corrupt=True,error=5))
 rows.append(run('no_presence',nopresence=True,error=3))
 rows.append(run('stuck_low',stuck=True,error=2))
 rows.append(run('conversion_timeout',busy=True,error=4))
 rows.append(run('held_abort',abort_at='held',error=6))
 for phase in ['reset','write','read']:rows.append(run('abort_'+phase,abort_at=phase,error=6))
 assert hashes()==frozen
 (HERE/'temperature_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,profiles=rows),indent=2)+'\n')
if __name__=='__main__':main()
